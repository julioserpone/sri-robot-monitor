import Foundation

struct CloudWatchLogEvent: Decodable, Sendable {
    let eventId: String
    let ingestionTime: Int64?
    let logStreamName: String?
    let message: String
    let timestamp: Int64

    var date: Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000)
    }
}

struct FilterLogEventsResult: Sendable {
    var events: [CloudWatchLogEvent]
    var nextToken: String?
}

struct CloudWatchLogsClient: Sendable {
    let client: AWSClient

    init(credentials: AWSCredentials, region: String, session: URLSession = .shared) {
        client = AWSClient(credentials: credentials, region: region, session: session)
    }

    /// `StartLiveTail` sobre `stream-logs.<región>.amazonaws.com`.
    ///
    /// A diferencia del sondeo, AWS empuja cada `sessionUpdate` (una vez por
    /// segundo) con las líneas recién ingeridas. La sesión de AWS se cierra
    /// sola a las 3 horas, así que la app la vuelve a abrir al terminar.
    ///
    /// Solo llegan los eventos ingeridos **después** de abrir la sesión: el
    /// histórico previo lo aporta `FilterLogEvents`.
    func startLiveTail(
        logGroupName: String,
        account: String? = nil,
        streams: [String]? = nil
    ) async throws -> AsyncThrowingStream<CloudWatchLogEvent, any Error> {
        let group = logGroupIdentifier(logGroupName, account: account)
        var body: [String: Any] = ["logGroupIdentifiers": [group]]
        if let streams, !streams.isEmpty {
            body["logStreamNames"] = streams
        }
        let payload = try JSONSerialization.data(withJSONObject: body, options: [])

        let request = try client.signedRequest(
            service: .logs,
            method: "POST",
            headers: [
                "Content-Type": "application/x-amz-json-1.1",
                "X-Amz-Target": "Logs_20140328.StartLiveTail",
                "Accept": "application/vnd.amazon.event-stream"
            ],
            body: payload,
            host: AWSService.logs.liveTailHost(client.region)
        )

        let (bytes, response) = try await client.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AWSNetworkError(underlying: "respuesta no HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65_536 { break }
            }
            throw client.apiError(
                statusCode: http.statusCode,
                data: data,
                headers: client.normalizedHeaders(http),
                service: .logs
            )
        }

        return AsyncThrowingStream<CloudWatchLogEvent, any Error> { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        let (frames, remainder) = AWSEventStreamDecoder.decode(buffer)
                        buffer = remainder
                        for frame in frames {
                            switch AWSEventStreamDecoder.parse(frame) {
                            case let .events(events):
                                for event in events { continuation.yield(event) }
                            case .started, .heartbeat, nil:
                                continue
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// `StartLiveTail` solo acepta ARN (o nombre de cuenta + grupo). La app
    /// conoce el número de cuenta por STS, así que se arma el ARN aquí.
    func logGroupIdentifier(_ name: String, account: String?) -> String {
        if name.hasPrefix("arn:") { return name }
        guard let account, !account.isEmpty else { return name }
        return "arn:aws:logs:\(client.region):\(account):log-group:\(name)"
    }

    func filterLogEvents(
        logGroupName: String,
        startTime: Date,
        endTime: Date? = nil,
        nextToken: String? = nil,
        limit: Int = 1_000
    ) async throws -> FilterLogEventsResult {
        let body = Self.filterLogEventsBody(
            logGroupName: logGroupName,
            startTime: startTime,
            endTime: endTime,
            nextToken: nextToken,
            limit: limit
        )
        let payload = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await filterLogEvents(payload: payload)
    }

    /// Cuerpo que espera `FilterLogEvents`. Se expone para poder probarlo sin
    /// credenciales.
    static func filterLogEventsBody(
        logGroupName: String,
        startTime: Date,
        endTime: Date?,
        nextToken: String?,
        limit: Int
    ) -> [String: Any] {
        var body: [String: Any] = [
            "logGroupName": logGroupName,
            "startTime": Int64(startTime.timeIntervalSince1970 * 1_000),
            "interleaved": true,
            "limit": limit
        ]
        if let endTime {
            body["endTime"] = Int64(endTime.timeIntervalSince1970 * 1_000)
        }
        if let nextToken {
            body["nextToken"] = nextToken
        }
        return body
    }

    private func filterLogEvents(payload: Data) async throws -> FilterLogEventsResult {
        let response = try await client.send(
            service: .logs,
            method: "POST",
            headers: [
                "Content-Type": "application/x-amz-json-1.1",
                "X-Amz-Target": "Logs_20140328.FilterLogEvents"
            ],
            body: payload
        )

        do {
            let decoded = try JSONDecoder().decode(FilterLogEventsResponse.self, from: response.data)
            return FilterLogEventsResult(
                events: decoded.events ?? [],
                nextToken: decoded.nextToken
            )
        } catch {
            throw AWSAPIError(
                service: "CloudWatch Logs",
                statusCode: response.statusCode,
                code: "InvalidResponse",
                message: "No se pudo interpretar la respuesta de CloudWatch Logs."
            )
        }
    }
}

private struct FilterLogEventsResponse: Decodable {
    let events: [CloudWatchLogEvent]?
    let nextToken: String?
}
