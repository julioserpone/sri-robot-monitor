import Foundation

/// Errores de la firma del modo `tail`.
enum AWSSignerTailError: LocalizedError {
    case invalidURL
    case missingAuthorization
    case malformedAuthorization

    var errorDescription: String? {
        switch self {
        case .invalidURL: "La URL de la invocación no es válida."
        case .missingAuthorization: "La petición no está firmada con SigV4."
        case .malformedAuthorization: "La cabecera Authorization no tiene el formato de SigV4."
        }
    }
}

extension AWSSigner {
    /// Datos de la sesión de firma de una petición, recuperados de su
    /// cabecera `Authorization` ya calculada.
    struct TailSignatureContext: Sendable {
        let amzDate: String
        let scope: String
        let signingKey: Data
    }

    /// La firma del cuerpo en streaming se deriva de la misma clave y fecha
    /// que la petición. Se lee de la cabecera `Authorization` en lugar de
    /// recalcularla, para no duplicar la lógica de la firma.
    static func tailContext(
        for request: URLRequest,
        credentials: AWSCredentials,
        region: String,
        service: String
    ) throws -> TailSignatureContext {
        guard let url = request.url, let host = url.host() else { throw AWSSignerTailError.invalidURL }
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              let amzDate = request.value(forHTTPHeaderField: "X-Amz-Date") else {
            throw AWSSignerTailError.missingAuthorization
        }

        let parts = authorizationParts(from: authorization)
        guard let credential = parts["Credential"],
              let signedHeaders = parts["SignedHeaders"],
              let givenSignature = parts["Signature"] else {
            throw AWSSignerTailError.malformedAuthorization
        }
        let credentialParts = credential.split(separator: "/")
        guard credentialParts.count == 5 else { throw AWSSignerTailError.malformedAuthorization }
        let scope = credentialParts.dropFirst().joined(separator: "/")

        var headerValues: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headerValues[name.lowercased()] = value
        }
        headerValues["host"] = host
        let canonicalHeaders = signedHeaders.split(separator: ";").map { name in
            "\(name):\(normalize(headerValues[String(name)] ?? ""))\n"
        }.joined()

        let canonicalRequest = [
            request.httpMethod?.uppercased() ?? "POST",
            canonicalPath(for: url),
            canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            sha256Hex(request.httpBody ?? Data())
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let dateStamp = String(amzDate.prefix(8))
        let key = signatureKey(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let expected = hmacSHA256(key: key, data: Data(stringToSign.utf8)).hexString
        guard expected == givenSignature else { throw AWSSignerTailError.malformedAuthorization }

        return TailSignatureContext(amzDate: amzDate, scope: scope, signingKey: key)
    }

    /// Firma de un trozo de evento (`AWS4-HMAC-SHA256-PAYLOAD`). Cada trozo
    /// encadena el hash de la firma anterior, así que AWS puede verificar el
    /// cuerpo a medida que llega.
    static func signTailChunk(
        context: TailSignatureContext,
        previousSignature: String,
        chunk: Data
    ) -> String {
        let stringToSign = [
            "AWS4-HMAC-SHA256-PAYLOAD",
            context.amzDate,
            context.scope,
            previousSignature,
            sha256Hex(Data()),
            sha256Hex(chunk)
        ].joined(separator: "\n")
        return hmacSHA256(key: context.signingKey, data: Data(stringToSign.utf8)).hexString
    }

    /// Cuerpo `aws-chunked` de `InvokeWithResponseStream`.
    ///
    /// Lambda espera el JSON del evento en un trozo propio y lo valida con el
    /// `Content-SHA256` que envía el encabezado de la petición. Antes va el
    /// trozo con el `content-type` y al final el trozo firmado de cierre.
    static func streamedInvocationBody(
        context: TailSignatureContext,
        requestSignature: String,
        payload: Data
    ) -> Data {
        let contentTypeFrame = "content-type:application/json\r\n\r\n"
        let contentTypeSignature = signTailChunk(
            context: context,
            previousSignature: requestSignature,
            chunk: Data(contentTypeFrame.utf8)
        )
        // Lambda decodifica el trozo antes de firmarlo: el cuerpo del evento
        // va precedido por su longitud.
        var payloadChunk = Data("content-length:\(payload.count)\r\n\r\n".utf8)
        payloadChunk.append(payload)
        let payloadSignature = signTailChunk(
            context: context,
            previousSignature: contentTypeSignature,
            chunk: payloadChunk
        )
        let finalFrame = ":chunk-signature=\(payloadSignature)\r\n\r\n"
        let finalSignature = signTailChunk(
            context: context,
            previousSignature: payloadSignature,
            chunk: Data(finalFrame.utf8)
        )

        var body = Data()
        appendEvent(&body, headers: .contentType, signature: contentTypeSignature, payload: Data())
        appendEvent(&body, headers: .payloadLength(payload.count), signature: payloadSignature, payload: payload)
        appendEvent(&body, headers: .payloadLength(payload.count), signature: finalSignature, payload: Data(), final: true)
        return body
    }

    /// Decodifica la respuesta `aws-chunked` de `InvokeWithResponseStream` y
    /// devuelve solo los trozos con contenido. El trozo de tamaño 0 cierra la
    /// trama.
    ///
    /// Cada trozo es `tamaño-hex[;extensión]\r\n[cabeceras\r\n]\r\n`
    /// seguido del contenido y `\r\n`. La primera trama solo lleva las
    /// cabeceras HTTP del pseudo-request (sin contenido): por eso se busca el
    /// final de cabeceras **después** de la línea de tamaño, y no de forma
    /// global.
    static func decodeChunkedPayload(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        var buffer = data
        while !buffer.isEmpty {
            guard let sizeEnd = buffer.range(of: Data("\r\n".utf8)) else { break }
            let sizeLine = String(data: buffer[buffer.startIndex..<sizeEnd.lowerBound], encoding: .utf8) ?? ""
            let token = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(token.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                break
            }

            // Tras `size \r\n` vienen `[cabeceras de trozo] \r\n` y luego
            // el contenido. Como esas cabeceras son opcionales, se acepta el
            // primer salto doble solo si quedan bytes suficientes para el
            // tamaño declarado; si no, el contenido empieza en la línea
            // siguiente a la del tamaño.
            var payloadStart = sizeEnd.upperBound
            if size > 0 {
                let afterSize = buffer[payloadStart...]
                if let blankLine = afterSize.range(of: Data("\r\n\r\n".utf8)),
                   buffer.distance(from: blankLine.upperBound, to: buffer.endIndex) >= size {
                    payloadStart = blankLine.upperBound
                }
            }

            guard let payloadEnd = buffer.index(payloadStart, offsetBy: size, limitedBy: buffer.endIndex) else {
                break
            }
            if size > 0 {
                chunks.append(Data(buffer[payloadStart..<payloadEnd]))
            }
            let next = min(payloadEnd + 2, buffer.endIndex)
            buffer = Data(buffer[next...])
            if size == 0 { break }
        }
        return chunks
    }

    private static func authorizationParts(from authorization: String) -> [String: String] {
        var result: [String: String] = [:]
        let body = authorization.replacingOccurrences(
            of: "AWS4-HMAC-SHA256 ",
            with: "",
            options: [.anchored]
        )
        for token in body.split(separator: ",") {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = token[token.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = token[token.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    /// Líneas de encabezado que AWS espera antes del contenido de un trozo.
    private enum ChunkHeaders {
        case contentType
        case payloadLength(Int)

        var text: String {
            switch self {
            case .contentType: "content-type:application/json\r\n"
            case let .payloadLength(length): "content-length:\(length)\r\n"
            }
        }
    }

    private static func appendEvent(
        _ body: inout Data,
        headers: ChunkHeaders,
        signature: String,
        payload: Data,
        final: Bool = false
    ) {
        _ = final
        body.append(Data("\(payload.count);chunk-signature=\(signature)\r\n".utf8))
        body.append(Data(headers.text.utf8))
        body.append(Data("\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n".utf8))
    }
}
