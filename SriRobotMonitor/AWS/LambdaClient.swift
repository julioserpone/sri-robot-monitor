import Foundation

struct LambdaClient: Sendable {
    let client: AWSClient

    init(credentials: AWSCredentials, region: String, session: URLSession = .shared) {
        client = AWSClient(credentials: credentials, region: region, session: session)
    }

    func configuration(functionName: String) async throws -> LambdaFunctionInfo {
        let encodedName = AWSSigner.encodePathSegment(functionName)
        let response = try await client.send(
            service: .lambda,
            method: "GET",
            path: "/2015-03-31/functions/\(encodedName)/configuration",
            headers: ["Accept": "application/json"]
        )
        do {
            return try JSONDecoder().decode(LambdaConfigurationResponse.self, from: response.data).info
        } catch {
            throw AWSAPIError(
                service: "Lambda",
                statusCode: response.statusCode,
                code: "InvalidResponse",
                message: "AWS devolvió una configuración de función que no se pudo interpretar."
            )
        }
    }

    /// Invoca la imagen ya publicada. `Event` responde en cuanto AWS acepta la
    /// ejecución, sin esperar a que termine el robot (que puede tardar minutos).
    func invoke(functionName: String, payload: RobotInvocationPayload) async throws -> String {
        let response = try await client.send(
            service: .lambda,
            method: "POST",
            path: "/2015-03-31/functions/\(AWSSigner.encodePathSegment(functionName))/invocations",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Amz-Invocation-Type": "Event"
            ],
            body: try encode(payload)
        )

        return response.header("x-amzn-requestid") ?? UUID().uuidString.lowercased()
    }

    /// Invocación síncrona (`RequestResponse`). Mantiene la conexión hasta que
    /// el robot termina y devuelve el resumen con fallos, descargas y claves.
    /// Es la vía para adjuntar variables de entorno secretas en el propio
    /// evento: cambiarlas en la función exigiría `UpdateFunctionConfiguration`.
    func invokeSync(functionName: String, payload: RobotInvocationPayload) async throws -> RobotInvocationResult {
        let body = try encode(payload)
        let response = try await client.sendWithLongerTimeout(
            service: .lambda,
            method: "POST",
            path: "/2015-03-31/functions/\(AWSSigner.encodePathSegment(functionName))/invocations",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Amz-Invocation-Type": "RequestResponse"
            ],
            body: body,
            timeout: 910
        )
        return Self.decodeResult(response.text)
    }

    /// Variables de entorno de la función. Lambda devuelve los valores en
    /// claro: la app solo consulta las claves para comprobar que existen y
    /// nunca las muestra ni las persiste.
    func environmentKeys(functionName: String) async throws -> Set<String> {
        let encodedName = AWSSigner.encodePathSegment(functionName)
        let response = try await client.send(
            service: .lambda,
            method: "GET",
            path: "/2015-03-31/functions/\(encodedName)/configuration",
            headers: ["Accept": "application/json"]
        )
        guard let data = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let environment = data["Environment"] as? [String: Any],
              let variables = environment["Variables"] as? [String: Any] else {
            return []
        }
        return Set(variables.keys)
    }

    /// La respuesta del modo `tail` puede llegar envuelta como API HTTP
    /// (`{"statusCode":…,"body":"…"}`) o ser directamente el JSON del resumen.
    static func decodeResult(_ text: String) -> RobotInvocationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let body = object["body"] as? String, !body.isEmpty {
            candidate = body
        } else {
            candidate = trimmed
        }

        guard let data = candidate.data(using: .utf8),
              let result = try? JSONDecoder().decode(RobotInvocationResult.self, from: data) else {
            let message = trimmed.isEmpty ? "La función no devolvió ningún resultado." : trimmed
            return RobotInvocationResult(ok: false, error: String(message.prefix(400)))
        }
        return result
    }

    private func encode(_ payload: RobotInvocationPayload) throws -> Data {
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw AWSAPIError(
                service: "Lambda",
                statusCode: 0,
                code: "EncodingError",
                message: "No se pudo construir el evento de la ejecución."
            )
        }
    }
}

private struct LambdaConfigurationResponse: Decodable {
    let functionName: String
    let state: String
    let lastUpdateStatus: String?
    let lastModified: String?
    let memorySize: Int?
    let timeout: Int?
    let codeSize: Int?
    let runtime: String?

    var info: LambdaFunctionInfo {
        LambdaFunctionInfo(
            functionName: functionName,
            state: state,
            lastUpdateStatus: lastUpdateStatus,
            lastModified: lastModified,
            memorySize: memorySize,
            timeout: timeout,
            codeSize: codeSize,
            runtime: runtime
        )
    }

    enum CodingKeys: String, CodingKey {
        case functionName = "FunctionName"
        case state = "State"
        case lastUpdateStatus = "LastUpdateStatus"
        case lastModified = "LastModified"
        case memorySize = "MemorySize"
        case timeout = "Timeout"
        case codeSize = "CodeSize"
        case runtime = "Runtime"
    }
}
