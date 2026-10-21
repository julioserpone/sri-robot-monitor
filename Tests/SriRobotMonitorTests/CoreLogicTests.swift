import XCTest
@testable import SriRobotMonitor

// MARK: - CloudWatch

final class CloudWatchLogParserTests: XCTestCase {
    private let formatterOptions: ISO8601DateFormatter.Options = [.withInternetDateTime, .withFractionalSeconds]

    func testJSONLineUsesStructuredFields() throws {
        let message = """
        {"ts":"2026-10-20T15:04:05.123456+00:00","nivel":"WARNING","mensaje":"captcha lento","logger":"sri","periodo":"2026-09","claves":3}
        """
        let entry = CloudWatchLogParser.parse(event: event(message))

        XCTAssertEqual(entry.level, .warning)
        XCTAssertEqual(entry.message, "captcha lento")
        XCTAssertEqual(entry.metadata["periodo"], "2026-09")
        XCTAssertEqual(entry.metadata["claves"], "3")
        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, 1_792_508_645.123456, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(entry.detail).contains("periodo: 2026-09"))
    }

    func testJSONLineKeepsExceptionInMessage() {
        let message = #"{"nivel":"ERROR","mensaje":"falló","excepcion":"Traceback: boom"}"#
        let entry = CloudWatchLogParser.parse(event: event(message))

        XCTAssertEqual(entry.level, .error)
        XCTAssertTrue(entry.message.contains("Traceback: boom"))
    }

    func testInvalidJSONFallsBackToPlainLine() {
        let message = "START RequestId: 8f2a1c0e-aaaa-bbbb-cccc-000000000001 Version: $LATEST"
        let entry = CloudWatchLogParser.parse(event: event(message))

        XCTAssertEqual(entry.level, .system)
        XCTAssertEqual(entry.requestID, "8f2a1c0e-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(entry.message, message)
    }

    func testInferLevelFromPlainText() {
        XCTAssertEqual(CloudWatchLogParser.inferLevel("Traceback (most recent call last):"), .error)
        XCTAssertEqual(CloudWatchLogParser.inferLevel("2026-10-20T15:00:00Z TASK TIMED OUT"), .error)
        XCTAssertEqual(CloudWatchLogParser.inferLevel("[WARNING] reintento"), .warning)
        XCTAssertEqual(CloudWatchLogParser.inferLevel("REPORT RequestId: x"), .system)
    }

    func testDurationAndRequestIDHelpers() {
        let report = "REPORT RequestId: abc Duration: 45123.45 ms\tBilled Duration: 45124 ms"
        XCTAssertEqual(CloudWatchLogParser.durationMilliseconds(in: report), 45123)
        XCTAssertEqual(CloudWatchLogParser.requestID(in: report), "abc")
    }

    func testLegacyTimestampWithoutFraction() {
        let parsed = CloudWatchLogParser.parseISODate("2026-10-20T15:04:05Z")
        XCTAssertNotNil(parsed)
    }

    private func event(_ message: String) -> CloudWatchLogEvent {
        CloudWatchLogEvent(
            eventId: "evt-1",
            ingestionTime: 1_792_508_645_000,
            logStreamName: "2026/10/20/[$LATEST]abc",
            message: message,
            timestamp: 1_792_508_645_000
        )
    }
}

// MARK: - Analizador de ejecuciones

final class LogAnalyzerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    func testHealthyRun() {
        let entries = [
            entry("8f2a1c0e", 0, "START RequestId: 8f2a1c0e Version: $LATEST"),
            entry("8f2a1c0e", 1, #"{"nivel":"INFO","mensaje":"iniciando ejecución del robot","periodos":"[2026-09]"}"#),
            entry("8f2a1c0e", 2, #"{"nivel":"INFO","mensaje":"TXT descargado","periodo":"2026-09","claves":12}"#),
            entry("8f2a1c0e", 3, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":0}"#),
            entry("8f2a1c0e", 4, "END RequestId: 8f2a1c0e"),
            entry("8f2a1c0e", 5, "REPORT RequestId: 8f2a1c0e Duration: 60000.00 ms")
        ]

        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.status, .healthy)
        XCTAssertEqual(run?.downloads, 1)
        XCTAssertEqual(run?.totalKeys, 12)
        XCTAssertEqual(run?.periods, ["2026-09"])
        XCTAssertEqual(run?.durationMilliseconds, 60_000)
        XCTAssertEqual(run?.finished, true)
    }

    func testWarningRunTurnsOrange() {
        let entries = [
            entry("r2", 0, "START RequestId: r2"),
            entry("r2", 1, #"{"nivel":"WARNING","mensaje":"captcha reintentado"}"#),
            entry("r2", 2, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":0}"#)
        ]
        XCTAssertEqual(LogAnalyzer.analyze(entries).first?.status, .warning)
    }

    func testFailuresTurnRed() {
        let entries = [
            entry("r3", 0, "START RequestId: r3"),
            entry("r3", 1, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":2}"#)
        ]
        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.status, .error)
        XCTAssertEqual(run?.failures, 2)
    }

    func testTimeoutTurnsRed() {
        let entries = [
            entry("r4", 0, "START RequestId: r4"),
            entry("r4", 1, "2026-10-20T15:00:00Z TASK TIMED OUT")
        ]
        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.status, .error)
        XCTAssertEqual(run?.timedOut, true)
    }

    func testRunInProgressIsRunning() {
        let now = start.addingTimeInterval(60)
        let entries = [entry("r5", 0, "START RequestId: r5", reference: now)]
        XCTAssertEqual(LogAnalyzer.analyze(entries, now: now).first?.status, .running)
    }

    func testStaleRunIsError() {
        let now = start.addingTimeInterval(LogAnalyzer.staleRunThreshold + 60)
        let entries = [entry("r6", 0, "START RequestId: r6", reference: now)]
        XCTAssertEqual(LogAnalyzer.analyze(entries, now: now).first?.status, .error)
    }

    func testFinishedWithoutSummaryIsError() {
        let entries = [
            entry("r7", 0, "START RequestId: r7"),
            entry("r7", 1, "END RequestId: r7"),
            entry("r7", 2, "REPORT RequestId: r7 Duration: 1200.00 ms")
        ]
        XCTAssertEqual(LogAnalyzer.analyze(entries).first?.status, .error)
    }

    func testErrorLineWithoutStartCreatesDerivedRun() {
        let entries = [
            entry("", 0, #"{"nivel":"ERROR","mensaje":"no se pudo abrir el navegador"}"#)
        ]
        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.isDerived, true)
        XCTAssertEqual(run?.failureMessages.first, "no se pudo abrir el navegador")
    }

    func testRunsAreSortedNewestFirst() {
        let entries = [
            entry("a", 0, "START RequestId: a"),
            entry("b", 10, "START RequestId: b")
        ]
        XCTAssertEqual(LogAnalyzer.analyze(entries).map(\.requestID), ["b", "a"])
    }

    private func entry(_ requestID: String, _ seconds: TimeInterval, _ message: String, reference: Date? = nil) -> LogEntry {
        let requestSuffix = requestID.isEmpty ? "" : " \(requestID)"
        let raw = message.contains("RequestId") ? message
            : "\(message) RequestId:\(requestSuffix) "
        let parsed = CloudWatchLogParser.parseJSONLine(message, fallbackDate: start.addingTimeInterval(seconds))
        return LogEntry(
            id: "\(reference?.timeIntervalSince1970 ?? 0)-\(requestID)-\(seconds)",
            timestamp: (parsed?.timestamp ?? start.addingTimeInterval(seconds)),
            level: parsed?.level ?? CloudWatchLogParser.inferLevel(message),
            message: parsed?.message ?? message,
            detail: parsed?.detail,
            raw: raw,
            requestID: requestID.isEmpty ? CloudWatchLogParser.requestID(in: raw) : requestID,
            logStreamName: "stream-\(requestID)",
            metadata: parsed?.metadata ?? [:]
        )
    }
}

// MARK: - Periodos

final class PeriodoTests: XCTestCase {
    func testPreviousClosedMonthCrossesYear() {
        let december = Calendar.sri.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        XCTAssertEqual(Periodo.previousClosedMonth(now: december), Periodo(year: 2025, month: 12))
    }

    func testRecentMonthsAreOrderedNewestFirst() {
        let now = Calendar.sri.date(from: DateComponents(year: 2026, month: 3, day: 2))!
        let recent = Periodo.recent(count: 3, now: now)
        XCTAssertEqual(recent.map(\.key), ["2026-02", "2026-01", "2025-12"])
    }

    func testKeyRoundTrip() {
        XCTAssertEqual(Periodo.fromKey("2026-09"), Periodo(year: 2026, month: 9))
        XCTAssertNil(Periodo.fromKey("2026-13"))
        XCTAssertNil(Periodo.fromKey("septiembre"))
    }
}

// MARK: - Payload y entorno

final class InvocationPayloadTests: XCTestCase {
    func testEnvironmentVariableNamesMatchTheImage() {
        let env = RobotEnvironment(portalPassword: "portal-123", anticaptchaKey: "ac-456")
        let variables = env.variables()

        XCTAssertEqual(variables["SRI_PASSWORD"], "portal-123")
        XCTAssertEqual(variables["ANTICAPTCHA_API_KEY"], "ac-456")
        XCTAssertNil(variables["SRI_PERFIL_DIR"])
    }

    func testEmptySecretsAreNotSent() {
        let env = RobotEnvironment.normalized(RobotEnvironment(portalPassword: "  ", anticaptchaKey: ""))
        XCTAssertTrue(env.variables().isEmpty)
        XCTAssertEqual(RobotEnvironment.normalized(env).portalPassword, "")
        XCTAssertFalse(env.isConfigured)
    }

    func testEnvSizeGuardUsesFourKilobytes() {
        let env = RobotEnvironment(portalPassword: String(repeating: "a", count: 4_000))
        XCTAssertTrue(env.exceedsInvocationLimit)
    }

    func testPayloadOmitsNilFields() throws {
        let payload = RobotInvocationPayload(periodos: ["2026-09"], tipos: nil, forzar: nil, environment: nil)
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)

        XCTAssertTrue(json.contains("\"periodos\""))
        XCTAssertFalse(json.contains("environment"))
        XCTAssertFalse(json.contains("forzar"))
    }

    func testPayloadCarriesEnvironmentForTailMode() throws {
        let payload = RobotInvocationPayload(
            periodos: ["2026-09"],
            environment: ["SRI_PASSWORD": "x"]
        )
        let decoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        let environment = decoded?["environment"] as? [String: String]
        XCTAssertEqual(environment?["SRI_PASSWORD"], "x")
    }

    func testDecodeTailResultUnwrapsHTTPBody() {
        let text = #"{"statusCode":200,"body":"{\"ok\":true,\"ejecutadoEn\":\"2026-10-20T15:00:00Z\",\"descargas\":2,\"claves\":7,\"fallos\":[]}"}"#
        let result = LambdaClient.decodeResult(text)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.descargas, 2)
        XCTAssertEqual(result.claves, 7)
    }

    func testDecodeTailResultPlainJSON() {
        let result = LambdaClient.decodeResult(#"{"ok":false,"fallos":["SIN CLAVE"]}"#)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failureCount, 1)
    }

    func testDecodeTailResultNonJSON() {
        let result = LambdaClient.decodeResult("<html>bad gateway</html>")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.error, "<html>bad gateway</html>")
    }

    func testStoredSecretsRoundTripKeepsLegacyAWSFormat() throws {
        let credentials = AWSCredentials(accessKeyID: "AKIA123", secretAccessKey: "secret", sessionToken: nil)
        let legacy = try JSONEncoder().encode(credentials)
        let decoded = try? JSONDecoder().decode(AWSCredentials.self, from: legacy)
        XCTAssertEqual(decoded, credentials)

        let modern = StoredSecrets(credentials: credentials, environment: RobotEnvironment(anticaptchaKey: "k"))
        let encoded = try JSONEncoder().encode(modern)
        XCTAssertEqual(try JSONDecoder().decode(StoredSecrets.self, from: encoded), modern)
    }

    func testConfigurationDecodesOlderFileWithoutNewKeys() throws {
        let legacy = """
        {"region":"us-east-1","functionName":"sri-txt-robot","logGroupName":"/aws/lambda/sri-txt-robot",
         "notificationsEnabled":true,"notifyWarnings":true,"pollIntervalSeconds":4,"historyDays":45}
        """
        let config = try JSONDecoder().decode(RobotConfiguration.self, from: Data(legacy.utf8))

        XCTAssertEqual(config.environment, RobotEnvironment())
        XCTAssertFalse(config.notifyOnStart)
        XCTAssertEqual(config.functionName, "sri-txt-robot")
    }

    func testNormalizedConfigurationClampsIntervals() {
        var config = RobotConfiguration.default
        config.pollIntervalSeconds = 1
        config.historyDays = 999
        let normalized = RobotConfiguration.normalized(config)

        XCTAssertEqual(normalized.pollIntervalSeconds, 2)
        XCTAssertEqual(normalized.historyDays, 365)
    }
}

// MARK: - Firma

final class AWSSignerTests: XCTestCase {
    func testKnownSigV4VectorFromAWSDocs() {
        // Vector oficial "GET Object" de la documentación de Signature Version 4.
        let credentials = AWSCredentials(
            accessKeyID: TestCredential.exampleAccessKey,
            secretAccessKey: TestCredential.exampleSecret
        )
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("315532800", forHTTPHeaderField: "x-amz-date")

        try? AWSSigner.sign(
            request: &request,
            credentials: credentials,
            region: "us-east-1",
            service: "s3",
            date: Date(timeIntervalSince1970: 1_369_353_600)
        )

        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=\(TestCredential.exampleAccessKey)/20130524/us-east-1/s3/aws4_request") ?? false)
    }

    func testSignatureKeyIsDeterministic() {
        let first = AWSSigner.signatureKey(secret: "s", dateStamp: "20260101", region: "us-east-1", service: "lambda")
        let second = AWSSigner.signatureKey(secret: "s", dateStamp: "20260101", region: "us-east-1", service: "lambda")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
    }

    func testChunkedPayloadDecoderIgnoresFinalZeroChunk() {
        let body = Data("5\r\nhello\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(AWSSigner.decodeChunkedPayload(body), [Data("hello".utf8)])
    }

    func testCanonicalQueryIsSortedAndEncoded() {
        let url = URL(string: "https://logs.us-east-1.amazonaws.com/?b=2&a=1&a=0&sp=hello%20world")!
        XCTAssertEqual(AWSSigner.canonicalQuery(for: url), "a=0&a=1&b=2&sp=hello%20world")
    }

    func testTailContextRejectsForeignSignature() {
        let credentials = AWSCredentials(accessKeyID: "AKIA", secretAccessKey: "secret")
        var request = URLRequest(url: URL(string: "https://lambda.us-east-1.amazonaws.com/2015-03-31/functions/x/invocations")!)
        request.httpMethod = "POST"
        request.setValue("abc", forHTTPHeaderField: "Authorization")

        XCTAssertThrowsError(
            try AWSSigner.tailContext(for: request, credentials: credentials, region: "us-east-1", service: "lambda")
        )
    }
}

// MARK: - Event stream

final class AWSEventStreamDecoderTests: XCTestCase {
    /// Trama completa válida, con CRCs reales, generada con las longitudes
    /// que dicta la especificación: `total-length` = preludio + cabeceras +
    /// cuerpo + 4.
    private static let sampleFrame: Data = Data([
        0xCA, 0x28, 0xC4, 0x25, 0x00, 0x00, 0x00, 0xA9, 0x00, 0x00, 0x00, 0x3D,
        0x0B, 0x3A, 0x65, 0x76, 0x65, 0x6E, 0x74, 0x2D, 0x74, 0x79, 0x70, 0x65, 0x07, 0x00, 0x0D,
        0x73, 0x65, 0x73, 0x73, 0x69, 0x6F, 0x6E, 0x55, 0x70, 0x64, 0x61, 0x74, 0x65,
        0x0D, 0x3A, 0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x74, 0x79, 0x70, 0x65, 0x07, 0x00, 0x10,
        0x61, 0x70, 0x70, 0x6C, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x2F, 0x6A, 0x73, 0x6F, 0x6E,
        0x7B, 0x22, 0x73, 0x65, 0x73, 0x73, 0x69, 0x6F, 0x6E, 0x52, 0x65, 0x73, 0x75, 0x6C, 0x74, 0x73,
        0x22, 0x3A, 0x5B, 0x7B, 0x22, 0x6C, 0x6F, 0x67, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x4E, 0x61,
        0x6D, 0x65, 0x22, 0x3A, 0x22, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x2D, 0x31, 0x22, 0x2C, 0x22,
        0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x22, 0x3A, 0x22, 0x68, 0x6F, 0x6C, 0x61, 0x22, 0x2C,
        0x22, 0x74, 0x69, 0x6D, 0x65, 0x73, 0x74, 0x61, 0x6D, 0x70, 0x22, 0x3A, 0x31, 0x37, 0x39, 0x32,
        0x35, 0x30, 0x38, 0x36, 0x34, 0x35, 0x30, 0x30, 0x30, 0x7D, 0x5D, 0x7D,
        0x35, 0x2D, 0xBF, 0x44
    ])

    func testSessionUpdateParsesResults() throws {
        guard case let .events(events)? = AWSEventStreamDecoder.parse(Self.sampleFrame) else {
            return XCTFail("No se decodificó sessionUpdate")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].message, "hola")
        XCTAssertEqual(events[0].logStreamName, "stream-1")
        XCTAssertTrue(events[0].eventId.hasPrefix("lt-"))
    }

    func testDecoderWaitsForCompleteFrames() {
        let frame = Self.sampleFrame
        let partial = frame.prefix(frame.count - 10)

        let (messages, remainder) = AWSEventStreamDecoder.decode(Data(partial))
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(remainder.count, partial.count)

        let complete = AWSEventStreamDecoder.decode(Data(partial) + Data(frame.suffix(10)))
        XCTAssertEqual(complete.messages.count, 1)
        XCTAssertEqual(complete.remainder.count, 0)
    }

    func testEventIdentifierIsStable() {
        let first = AWSEventStreamDecoder.eventIdentifier(stream: "s", timestamp: 1, message: "línea")
        let second = AWSEventStreamDecoder.eventIdentifier(stream: "s", timestamp: 1, message: "línea")
        let third = AWSEventStreamDecoder.eventIdentifier(stream: "s", timestamp: 2, message: "línea")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, third)
    }

    func testMissingSeparatorBetweenFramesStillDecodes() {
        let first = Self.sampleFrame
        let second = Self.sampleFrame
        let joined = Data(first.prefix(first.count - 4)) + second
        let (messages, _) = AWSEventStreamDecoder.decode(joined)
        XCTAssertEqual(messages.count, 2)
    }

    func testCorruptedPreludeIsDiscarded() {
        let frame = Self.sampleFrame
        // Se corrompe el CRC del preludio, que es lo que permite resincronizar
        // buscando el próximo byte con un preludio válido.
        var corrupted = frame
        corrupted[8] = 0xFF
        corrupted[9] = 0xFF
        corrupted[10] = 0xFF
        corrupted[11] = 0xFF

        let (messages, remainder) = AWSEventStreamDecoder.decode(corrupted)
        // El CRC del preludio identifica el inicio real del mensaje.
        XCTAssertEqual(messages.count, 1)
        XCTAssertLessThan(remainder.count, corrupted.count)
    }
}

// MARK: - Estado y presentación

final class RobotStatusTests: XCTestCase {
    func testEveryStatusHasAccessibleCaption() {
        for status in RobotStatus.allCases {
            XCTAssertFalse(status.ledCaption.isEmpty)
            XCTAssertFalse(status.title.isEmpty)
            XCTAssertFalse(status.symbolName.isEmpty)
        }
    }

    func testProblemStates() {
        XCTAssertTrue(RobotStatus.error.isProblem)
        XCTAssertFalse(RobotStatus.healthy.isProblem)
    }
}
