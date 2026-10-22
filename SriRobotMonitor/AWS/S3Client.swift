import Foundation

/// Un objeto de S3 que puede descargarse desde la app.
struct S3Object: Identifiable, Sendable, Hashable {
    let bucket: String
    let key: String

    var id: String { "\(bucket)/\(key)" }

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
    /// El robot publica en
    /// `facturas-recibidas/{ambiente}/{año}/{mes}/raw/` los TXT y en
    /// `facturas-recibidas/{ambiente}/{año}/{mes}/manifest/` los JSON. Se
    /// buscan ambos prefijos y se cruzan por RUC y período.
    func findArtifacts(
        bucket: String,
        environment: String,
        periods: [String],
        ruc: String?
    ) async throws -> [S3Object] {
        guard !periods.isEmpty else { return [] }
        var objects: [S3Object] = []

        for period in periods {
            for folder in ["raw", "manifest"] {
                let prefix = String(
                    format: "facturas-recibidas/%@/%@/%@/%@/",
                    environment,
                    String(period.prefix(4)),
                    String(period.suffix(2)),
                    folder
                )
                let keys = try await listKeys(bucket: bucket, prefix: prefix)
                for key in keys {
                    if let ruc, !key.contains(ruc) { continue }
                    objects.append(S3Object(bucket: bucket, key: key))
                }
            }
        }

        // Si el ambiente o el layout no coincide, se intenta un barrido más
        // ancho por RUC + período antes de rendirse.
        if objects.isEmpty {
            for period in periods {
                let prefix = String(
                    format: "facturas-recibidas/%@/%@/",
                    String(period.prefix(4)),
                    String(period.suffix(2))
                )
                let keys = try await listKeys(bucket: bucket, prefix: prefix)
                for key in keys where key.hasSuffix(".txt") || key.hasSuffix(".json") {
                    if let ruc, !key.contains(ruc) { continue }
                    objects.append(S3Object(bucket: bucket, key: key))
                }
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

    /// Lista hasta 1 000 claves bajo un prefijo.
    func listKeys(bucket: String, prefix: String, continuationToken: String? = nil) async throws -> [String] {
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
        return decoder.keys
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
    private var current = ""
    private var buffer = ""

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
        if elementName == "Key" {
            let key = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { keys.append(key) }
        }
        current = ""
        buffer = ""
    }
}
