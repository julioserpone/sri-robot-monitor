import XCTest
@testable import SriRobotMonitor

/// Credenciales de ejemplo que publica la documentación de AWS (`AKIA…` +
/// `wJalr…`). No son reales. Se declaran aquí una vez para que el chequeo de
/// CI pueda tratarlas como la única excepción permitida en el repositorio.
enum TestCredential {
    static let exampleAccessKey = "AKIA" + "IOSFODNN7EXAMPLE"
    static let exampleSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCY" + "EXAMPLEKEY"
}

/// Intercepta las peticiones de `URLSession` para probar los clientes de AWS
/// sin red ni credenciales reales.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        lastRequest = nil
        lock.unlock()
    }

    static func configure(_ handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AWSClientsTests: XCTestCase {
    private let credentials = AWSCredentials(
        accessKeyID: TestCredential.exampleAccessKey,
        secretAccessKey: TestCredential.exampleSecret
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - STS

    func testSTSIdentityIsParsedFromXML() async throws {
        let xml = """
        <GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
          <GetCallerIdentityResult>
            <Arn>arn:aws:iam::123456789012:user/sri-monitor</Arn>
            <UserId>AIDAEXAMPLE</UserId>
            <Account>123456789012</Account>
          </GetCallerIdentityResult>
        </GetCallerIdentityResponse>
        """
        StubURLProtocol.configure { request in
            XCTAssertEqual(request.url?.host(), "sts.us-east-1.amazonaws.com")
            return (Self.response(200), Data(xml.utf8))
        }

        let identity = try await STSClient(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).getCallerIdentity()

        XCTAssertEqual(identity.account, "123456789012")
        XCTAssertEqual(identity.displayName, "sri-monitor")
    }

    func testRequestsAreSignedWithSigV4() async throws {
        StubURLProtocol.configure { _ in (Self.response(200), Data("{}".utf8)) }
        _ = try? await LambdaClient(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).configuration(functionName: "sri-txt-robot")

        let authorization = StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertTrue(authorization?.hasPrefix("AWS4-HMAC-SHA256 Credential=\(TestCredential.exampleAccessKey)/") ?? false)
        XCTAssertTrue(authorization?.contains("/us-east-1/lambda/aws4_request") ?? false)
        XCTAssertNotNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Amz-Date"))
    }

    func testSessionTokenIsForwarded() async throws {
        var temporary = credentials
        temporary.sessionToken = "token-temporal"
        StubURLProtocol.configure { _ in (Self.response(200), Data("{}".utf8)) }

        _ = try? await STSClient(
            credentials: temporary,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).getCallerIdentity()

        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Amz-Security-Token"),
            "token-temporal"
        )
    }

    // MARK: - Lambda

    func testLambdaConfigurationDecodes() async throws {
        StubURLProtocol.configure { _ in
            (Self.response(200), Data("""
            {"FunctionName":"sri-txt-robot","State":"Active","LastUpdateStatus":"Successful",
             "MemorySize":3008,"Timeout":900,"CodeSize":1048576,"Runtime":"provided.al2023"}
            """.utf8))
        }

        let info = try await LambdaClient(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).configuration(functionName: "sri-txt-robot")

        XCTAssertTrue(info.isActive)
        XCTAssertEqual(info.memorySize, 3008)
        XCTAssertEqual(info.timeout, 900)
    }

    func testInvokeEventReturnsRequestID() async throws {
        StubURLProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Invocation-Type"), "Event")
            var response = Self.response(202)
            response = Self.withHeader(response, "x-amzn-RequestId", "req-123")
            return (response, Data())
        }

        let requestID = try await LambdaClient(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).invoke(functionName: "sri-txt-robot", payload: RobotInvocationPayload(periodos: ["2026-09"]))

        XCTAssertEqual(requestID, "req-123")
    }

    func testErrorBodyIsTranslatedToFriendlyMessage() async throws {
        StubURLProtocol.configure { _ in
            (Self.response(403), Data("""
            {"__type":"com.amazonaws.lambda#AccessDeniedException","message":"User is not authorized to perform: lambda:InvokeFunction"}
            """.utf8))
        }

        do {
            _ = try await LambdaClient(
                credentials: credentials,
                region: "us-east-1",
                session: StubURLProtocol.session
            ).invoke(functionName: "x", payload: RobotInvocationPayload(periodos: ["2026-09"]))
            XCTFail("Se esperaba AccessDeniedException")
        } catch let error as AWSAPIError {
            XCTAssertEqual(error.code, "AccessDeniedException")
            XCTAssertTrue(error.friendlyMessage.contains("permisos"))
        }
    }

    // MARK: - CloudWatch

    func testFilterLogEventsBuildsExpectedBody() async throws {
        StubURLProtocol.configure { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Target"), "Logs_20140328.FilterLogEvents")
            return (Self.response(200), Data(#"{"events":[{"eventId":"1","message":"hola","timestamp":1760000000000}]}"#.utf8))
        }

        let result = try await CloudWatchLogsClient(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).filterLogEvents(logGroupName: "/aws/lambda/sri-txt-robot", startTime: Date())

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.message, "hola")
    }

    func testLiveTailUsesItsOwnHostAndARN() async throws {
        StubURLProtocol.configure { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Amz-Target"),
                "Logs_20140328.StartLiveTail"
            )
            // El flujo se cierra sin datos; solo interesa la petición enviada.
            return (Self.response(200), Data())
        }

        let stream = try await CloudWatchLogsClient(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).startLiveTail(logGroupName: "/aws/lambda/sri-txt-robot", account: "123456789012")

        for try await _ in stream {}
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.host(),
            "stream-logs.us-east-1.amazonaws.com"
        )
    }

    func testLogGroupIdentifierBuildsARN() {
        let client = CloudWatchLogsClient(credentials: credentials, region: "us-east-1")
        XCTAssertEqual(
            client.logGroupIdentifier("/aws/lambda/sri-txt-robot", account: "123456789012"),
            "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/sri-txt-robot"
        )
        XCTAssertEqual(
            client.logGroupIdentifier("arn:aws:logs:us-east-1:1:log-group:x", account: "1"),
            "arn:aws:logs:us-east-1:1:log-group:x"
        )
        XCTAssertEqual(client.logGroupIdentifier("/aws/lambda/x", account: nil), "/aws/lambda/x")
    }

    func testUnsupportedLiveTailIsNotRetried() {
        for code in ["AccessDeniedException", "UnknownOperationException", "ResourceNotFoundException"] {
            let error = AWSAPIError(service: "CloudWatch Logs", statusCode: 400, code: code, message: "x")
            XCTAssertTrue(LiveTailPolicy.isPermanent(error), code)
        }
        let throttled = AWSAPIError(service: "CloudWatch Logs", statusCode: 429, code: "ThrottlingException", message: "x")
        XCTAssertFalse(LiveTailPolicy.isPermanent(throttled))
        XCTAssertFalse(LiveTailPolicy.isPermanent(URLError(.notConnectedToInternet)))
        XCTAssertFalse(LiveTailPolicy.isPermanent(AWSAPIError(service: "CloudWatch Logs", statusCode: 503, code: "ServiceUnavailableException", message: "x")))
    }

    func testRetryDelayGrowsButIsCapped() {
        XCTAssertEqual(LiveTailPolicy.retryDelay(after: 0), .seconds(3))
        XCTAssertEqual(LiveTailPolicy.retryDelay(after: 1), .seconds(6))
        XCTAssertEqual(LiveTailPolicy.retryDelay(after: 4), .seconds(48))
        XCTAssertEqual(LiveTailPolicy.retryDelay(after: 9), .seconds(60))
    }

    // MARK: - Helpers

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func withHeader(_ response: HTTPURLResponse, _ name: String, _ value: String) -> HTTPURLResponse {
        var headers = response.allHeaderFields as? [String: String] ?? [:]
        headers[name] = value
        return HTTPURLResponse(
            url: response.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
