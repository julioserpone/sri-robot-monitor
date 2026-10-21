import Foundation

struct AWSResponse: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var text: String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

struct AWSAPIError: LocalizedError, Sendable {
    let service: String
    let statusCode: Int
    let code: String
    let message: String

    var errorDescription: String? {
        "\(service.uppercased()) \(statusCode) · \(code): \(message)"
    }

    var friendlyMessage: String {
        switch code {
        case "InvalidClientTokenId", "UnrecognizedClientException", "SignatureDoesNotMatch":
            "Las credenciales de AWS no son válidas o la clave secreta no coincide."
        case "ExpiredToken", "ExpiredTokenException":
            "La sesión temporal de AWS caducó. Vuelve a introducir las credenciales."
        case "AccessDeniedException", "AccessDenied", "UnauthorizedOperation":
            "Las credenciales son válidas, pero no tienen permisos para esta operación."
        case "ResourceNotFoundException":
            "No se encontró el recurso en AWS. Revisa el nombre de la función o del log group."
        case "ResourceNotFound", "FunctionNotFound":
            "No existe la función de Lambda indicada."
        case "ThrottlingException", "Throttling", "TooManyRequestsException":
            "AWS está limitando las peticiones. Se reintentará en unos segundos."
        case "RequestTimeout", "RequestTimeoutException":
            "AWS no respondió a tiempo. Revisa la conexión e inténtalo de nuevo."
        default:
            message
        }
    }
}

struct AWSNetworkError: LocalizedError, Sendable {
    let underlying: String

    var errorDescription: String? {
        "No se pudo conectar con AWS: \(underlying)"
    }
}

/// Cliente HTTP firmado con SigV4 para los tres servicios que usa la app:
/// STS, Lambda y CloudWatch Logs.
struct AWSClient: Sendable {
    let credentials: AWSCredentials
    let region: String
    let session: URLSession

    init(credentials: AWSCredentials, region: String, session: URLSession = .shared) {
        self.credentials = credentials
        self.region = region
        self.session = session
    }

    func send(
        service: AWSService,
        method: String,
        path: String = "/",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data()
    ) async throws -> AWSResponse {
        let request = try signedRequest(
            service: service,
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )

        return try await perform(request, service: service)
    }

    /// Igual que `send`, pero mantiene abierta la conexión más tiempo. El
    /// robot tarda 45-60 s y Lambda corta a los 900 s.
    func sendWithLongerTimeout(
        service: AWSService,
        method: String,
        path: String = "/",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        timeout: TimeInterval
    ) async throws -> AWSResponse {
        let request = try signedRequest(
            service: service,
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            timeout: timeout
        )
        return try await perform(request, service: service)
    }

    private func perform(_ request: URLRequest, service: AWSService) async throws -> AWSResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AWSNetworkError(underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AWSNetworkError(underlying: "respuesta no HTTP")
        }

        let result = AWSResponse(
            statusCode: http.statusCode,
            data: data,
            headers: normalizedHeaders(http)
        )
        guard (200..<300).contains(http.statusCode) else {
            throw parseError(result, service: service)
        }
        return result
    }

    /// Petición firmada, sin enviarla. La usan Live Tail, que necesita la
    /// cabecera firmada antes de abrir el flujo de respuesta.
    func signedRequest(
        service: AWSService,
        method: String,
        path: String = "/",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data = Data(),
        timeout: TimeInterval = 45,
        host override: String? = nil
    ) throws -> URLRequest {
        guard let url = makeURL(service: service, path: path, query: query, host: override) else {
            throw AWSSignerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        try AWSSigner.sign(
            request: &request,
            credentials: credentials,
            region: region,
            service: service.signingName
        )
        return request
    }

    func normalizedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }

    /// Reconstruye el error de AWS a partir del cuerpo ya leído (Live Tail y
    /// el modo `tail` leen la respuesta como bytes, no con `send`).
    func apiError(from data: Data, headers: [String: String], service: AWSService) -> AWSAPIError {
        parseError(AWSResponse(statusCode: 400, data: data, headers: headers), service: service)
    }

    /// Para respuestas en streaming se conoce el código HTTP pero el cuerpo
    /// solo se lee si hace falta; este atajo evita inventarse un 400.
    func apiError(
        statusCode: Int,
        data: Data,
        headers: [String: String],
        service: AWSService
    ) -> AWSAPIError {
        parseError(
            AWSResponse(statusCode: statusCode, data: data, headers: headers),
            service: service
        )
    }

    func makeURL(
        service: AWSService,
        path: String,
        query: [URLQueryItem],
        host override: String? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = override ?? service.host(region: region)
        let normalizedPath = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        components.percentEncodedPath = normalizedPath
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url
    }

    private func parseError(_ response: AWSResponse, service: AWSService) -> AWSAPIError {
        let text = response.text
        var code = "HTTP\(response.statusCode)"
        var message = text.isEmpty ? "Respuesta vacía de AWS." : text

        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let raw = object["__type"] as? String ?? object["code"] as? String ?? object["Code"] as? String {
                code = raw.split(separator: "#").last.map(String.init) ?? raw
            }
            if let raw = object["message"] as? String ?? object["Message"] as? String {
                message = raw
            }
        } else {
            code = firstXMLValue(in: text, tag: "Code") ?? code
            message = firstXMLValue(in: text, tag: "Message") ?? message
        }

        return AWSAPIError(
            service: service.displayName,
            statusCode: response.statusCode,
            code: code,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func firstXMLValue(in text: String, tag: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"),
              let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }
}

enum AWSService: String, Sendable {
    case sts
    case lambda
    case logs

    var signingName: String {
        switch self {
        case .sts: "sts"
        case .lambda: "lambda"
        case .logs: "logs"
        }
    }

    var displayName: String {
        switch self {
        case .sts: "STS"
        case .lambda: "Lambda"
        case .logs: "CloudWatch Logs"
        }
    }

    func host(region: String) -> String {
        switch self {
        case .sts:
            return "sts.\(region).amazonaws.com"
        case .lambda:
            return "lambda.\(region).amazonaws.com"
        case .logs:
            return "logs.\(region).amazonaws.com"
        }
    }

    /// `StartLiveTail` usa inyección de host propio y no responde en
    /// `logs.<región>.amazonaws.com`.
    var liveTailHost: (String) -> String {
        { region in "stream-logs.\(region).amazonaws.com" }
    }
}
