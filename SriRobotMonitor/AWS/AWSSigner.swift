import CryptoKit
import Foundation

enum AWSSignerError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: "La URL de la petición AWS no es válida."
        }
    }
}

/// Implementación mínima y sin dependencias de AWS Signature Version 4.
///
/// Se firman únicamente las cabeceras que añade la app (`content-type`,
/// `x-amz-target`, `x-amz-content-sha256`) y `host`. URLSession calcula el
/// resto después de firmar, así que no deben formar parte de la firma.
enum AWSSigner {
    private static let algorithm = "AWS4-HMAC-SHA256"

    static func sign(
        request: inout URLRequest,
        credentials: AWSCredentials,
        region: String,
        service: String,
        date: Date = Date()
    ) throws {
        guard let url = request.url, let host = url.host() else {
            throw AWSSignerError.invalidURL
        }

        let amzDate = timestamp(date)
        let dateStamp = String(amzDate.prefix(8))

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        var headerValues: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            guard !Self.ignoredHeaders.contains(lower) else { continue }
            headerValues[lower] = value
        }
        headerValues["host"] = host

        let signedHeaderNames = headerValues.keys.sorted()
        let canonicalHeaders = signedHeaderNames
            .map { "\($0):\(normalize(headerValues[$0] ?? ""))\n" }
            .joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let payloadHash = sha256Hex(request.httpBody ?? Data())
        let canonicalRequest = [
            request.httpMethod?.uppercased() ?? "GET",
            canonicalPath(for: url),
            canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = signatureKey(secret: credentials.secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        let signature = hmacSHA256(key: signingKey, data: Data(stringToSign.utf8)).hexString

        let authorization = "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    static func canonicalQuery(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let pairs = (components.queryItems ?? []).map { item in
            (awsEncode(item.name), awsEncode(item.value ?? ""))
        }
        return pairs
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func canonicalPath(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "/" }
        let path = components.percentEncodedPath
        return path.isEmpty ? "/" : path
    }

    static func awsEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func encodePathSegment(_ value: String) -> String {
        awsEncode(value)
    }

    /// Codifica una clave de S3 conservando las `/` de separación: cada
    /// segmento se codifica por separado, como exige SigV4.
    static func encodeS3Key(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { awsEncode(String($0)) }
            .joined(separator: "/")
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static let ignoredHeaders: Set<String> = [
        "authorization",
        "host",
        "content-length",
        "user-agent",
        "accept-encoding",
        "connection"
    ]

    internal static func signatureKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmacSHA256(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        return hmacSHA256(key: kService, data: Data("aws4_request".utf8))
    }

    internal static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
