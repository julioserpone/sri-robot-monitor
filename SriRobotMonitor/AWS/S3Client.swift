import Foundation

/// Un objeto de S3 que puede descargarse desde la app.
struct S3Object: Identifiable, Sendable, Hashable {
    let bucket: String
    let key: String
    /// Metadatos que devuelve el listado. Sirven para ordenar y para mostrar
    /// el tamaño en el explorador; no hacen falta para descargar.
    var size: Int?
    var lastModified: Date?

    init(bucket: String, key: String, size: Int? = nil, lastModified: Date? = nil) {
        self.bucket = bucket
        self.key = key
        self.size = size
        self.lastModified = lastModified
    }

    var id: String { "\(bucket)/\(key)" }

    /// Tamaño legible (`1,2 MB`).
    var sizeText: String? {
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: Int64(size))
    }

    var fileName: String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    /// Distingue el TXT descargado del portal del JSON con las claves.
    var kind: DownloadKind {
        key.lowercased().hasSuffix(".txt") ? .txt : .json
    }
}

enum DownloadKind: String, Sendable, CaseIterable {
    case txt
    case json

    var title: String {
        switch self {
        case .txt: "TXT del portal"
        case .json: "JSON de claves"
        }
    }

    var symbol: String {
        switch self {
        case .txt: "doc.plaintext"
        case .json: "curlybraces"
        }
    }
}

/// Cliente mínimo de S3 (firma SigV4, `ListObjectsV2` y `GetObject`).
///
/// Solo se usa para bajar lo que el robot ya dejó escrito: la app nunca escribe
/// ni borra objetos.
struct S3Client: Sendable {
    let client: AWSClient

    init(credentials: AWSCredentials, region: String, session: URLSession = .shared) {
        client = AWSClient(credentials: credentials, region: region, session: session)
    }

    /// Busca TXT y JSON de una ejecución.
    ///
    /// El layout real del robot es:
    ///
    /// ```
    /// {ambiente}/{timestamp}/{año-mes}/facturas-recibidas-{año-mes}.txt
    /// {ambiente}/{timestamp}/{año-mes}/…claves….json
    /// ```
    ///
    /// (por ejemplo `produccion/1758871873001/2026-05/facturas-recibidas-2026-05.txt`).
    /// El `timestamp` es distinto en cada ejecución, así que se lista el mes
    /// completo y se filtra por el período. Se prueban además los layouts
    /// anteriores (`facturas-recibidas/{ambiente}/{año}/{mes}/raw|manifest/`)
    /// para no romper con buckets ya existentes.
    func findArtifacts(
        bucket: String,
        environment: String,
        periods: [String],
        ruc: String?
    ) async throws -> [S3Object] {
        guard !periods.isEmpty else { return [] }

        var prefixes: [String] = []
        for period in periods {
            let year = String(period.prefix(4))
            let month = String(period.suffix(2))
            // Layout actual: solo el ambiente, porque el timestamp de la
            // ejecución cambia en cada corrida y no se conoce de antemano.
            prefixes.append("\(environment)/")
            // Layout anterior, por si el bucket es antiguo.
            prefixes.append("facturas-recibidas/\(environment)/\(year)/\(month)/raw/")
            prefixes.append("facturas-recibidas/\(environment)/\(year)/\(month)/manifest/")
        }

        var objects: [S3Object] = []
        for prefix in Set(prefixes) {
            let keys = try await listKeys(bucket: bucket, prefix: prefix)
            for key in keys where Self.matches(key: key, periods: periods, ruc: ruc) {
                objects.append(S3Object(bucket: bucket, key: key))
            }
        }

        // Si el ambiente configurado no coincide con el de la ruta, se busca el
        // período en todo el bucket antes de rendirse.
        if objects.isEmpty {
            let root = try await listKeys(bucket: bucket, prefix: "")
            for key in root where Self.matches(key: key, periods: periods, ruc: ruc) {
                objects.append(S3Object(bucket: bucket, key: key))
            }
        }

        // Un TXT y un JSON por archivo; se devuelve uno de cada tipo y se
        // prefiere el más reciente si hubiera varios para el mismo RUC.
        var unique: [DownloadKind: S3Object] = [:]
        for object in objects {
            unique[object.kind] = object
        }
        return unique.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Una clave pertenece a la ejecución si su ruta contiene el mes (`2026-05`
    /// o `2026/05`) y, si se conoce el RUC, también lo menciona.
    static func matches(key: String, periods: [String], ruc: String?) -> Bool {
        let lower = key.lowercased()
        guard lower.hasSuffix(".txt") || lower.hasSuffix(".json") else { return false }
        if let ruc, !ruc.isEmpty, !key.contains(ruc) { return false }
        guard !periods.isEmpty else { return true }
        return periods.contains { period in
            let compact = String(period.prefix(7))          // 2026-05
            let slashed = period.prefix(4) + "/" + period.suffix(2) // 2026/05
            return lower.contains(compact.lowercased()) || lower.contains(slashed)
        }
    }

    /// Lista hasta 1 000 claves bajo un prefijo.
    func listKeys(bucket: String, prefix: String, continuationToken: String? = nil) async throws -> [String] {
        try await listObjects(bucket: bucket, prefix: prefix, continuationToken: continuationToken).keys
    }

    /// Una página del listado: claves y marcador para pedir la siguiente.
    func listObjects(
        bucket: String,
        prefix: String = "",
        continuationToken: String? = nil
    ) async throws -> (objects: [S3Object], keys: [String], nextToken: String?) {
        let query = Self.listQuery(prefix: prefix, token: continuationToken)
        let response = try await client.send(
            service: .s3,
            method: "GET",
            path: Self.bucketPath(bucket),
            query: query
        )
        let decoder = S3ListParser()
        let parser = XMLParser(data: response.data)
        parser.delegate = decoder
        guard parser.parse() else {
            throw AWSAPIError(
                service: "S3",
                statusCode: response.statusCode,
                code: "InvalidResponse",
                message: "No se pudo leer el listado de S3."
            )
        }
        let objects = decoder.keys.map {
            S3Object(
                bucket: bucket,
                key: $0,
                size: decoder.sizes[$0],
                lastModified: decoder.dates[$0]
            )
        }
        return (objects, decoder.keys, decoder.nextToken)
    }

    /// Descarga un objeto completo.
    func getObject(_ object: S3Object) async throws -> Data {
        let response = try await client.send(
            service: .s3,
            method: "GET",
            path: "/" + Self.bucketPathSegment(object.bucket) + "/" + AWSSigner.encodeS3Key(object.key)
        )
        return response.data
    }

    /// Resumen legible del resultado para la interfaz.
    static func listQuery(prefix: String, token: String?) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: prefix),
            URLQueryItem(name: "max-keys", value: "1000")
        ]
        if let token {
            query.append(URLQueryItem(name: "continuation-token", value: token))
        }
        return query
    }

    static func bucketPath(_ bucket: String) -> String {
        "/" + bucketPathSegment(bucket)
    }

    /// El nombre del bucket no se codifica más allá de los caracteres que
    /// romperían la URL; la clave sí se codifica por segmentos, conservando
    /// las barras que separan las carpetas de S3.
    static func bucketPathSegment(_ bucket: String) -> String {
        bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?")))
            ?? bucket
    }
}

private final class S3ListParser: NSObject, XMLParserDelegate {
    private(set) var keys: [String] = []
    private(set) var nextToken: String?
    /// Tamaño y fecha de cada clave, en el mismo orden que `keys`.
    private(set) var sizes: [String: Int] = [:]
    private(set) var dates: [String: Date] = [:]
    private var current = ""
    private var buffer = ""
    private var currentKey: String?

    /// `ISO8601DateFormatter` no es `Sendable`, así que se crea por llamada en
    /// lugar de compartirlo: el listado trae pocas fechas.
    private static func parseDate(_ value: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime]
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        current = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key":
            if !value.isEmpty {
                keys.append(value)
                currentKey = value
            }
        case "Size":
            if let key = currentKey, let size = Int(value) { sizes[key] = size }
        case "LastModified":
            if let key = currentKey, let date = Self.parseDate(value) {
                dates[key] = date
            }
        case "NextContinuationToken":
            if !value.isEmpty { nextToken = value }
        default:
            break
        }
        current = ""
        buffer = ""
    }
}
