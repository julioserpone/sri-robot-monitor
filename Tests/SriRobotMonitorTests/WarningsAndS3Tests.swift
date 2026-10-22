import Foundation
import XCTest
@testable import SriRobotMonitor

/// Las advertencias se contaban pero no se explicaban: el LED salía naranja y
/// la app no decía por qué. Estas pruebas fijan que el texto llegue al detalle.
final class WarningDetailTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    func testWarningTextIsKeptForTheDetail() {
        let entries = [
            entry("r1", 0, "START RequestId: r1"),
            entry("r1", 1, #"{"nivel":"WARNING","mensaje":"El captcha se resolvió por api key","logger":"sri.captcha"}"#),
            entry("r1", 2, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":0}"#)
        ]

        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.status, .warning)
        XCTAssertEqual(run?.warningCount, 1)
        XCTAssertEqual(run?.warningMessages, ["El captcha se resolvió por api key"])
        XCTAssertEqual(run?.warningSummary, "El captcha se resolvió por api key")
        XCTAssertEqual(run?.statusExplanation, "El captcha se resolvió por api key")
    }

    func testRepeatedWarningsAreDeduplicated() {
        let entries = [
            entry("r2", 0, "START RequestId: r2"),
            entry("r2", 1, #"{"nivel":"WARNING","mensaje":"reintento del portal"}"#),
            entry("r2", 2, #"{"nivel":"WARNING","mensaje":"reintento del portal"}"#),
            entry("r2", 3, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":0}"#)
        ]

        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.warningCount, 2)
        XCTAssertEqual(run?.warningMessages, ["reintento del portal"])
        XCTAssertEqual(run?.warningSummary, "reintento del portal (y 1 más)")
    }

    func testPlainTextWarningIsCaptured() {
        let entries = [
            entry("r3", 0, "START RequestId: r3"),
            entry("r3", 1, "[WARNING] sin claves para 2026-08"),
            entry("r3", 2, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":0}"#)
        ]

        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.status, .warning)
        XCTAssertEqual(run?.warningMessages.first, "[WARNING] sin claves para 2026-08")
    }

    func testHealthyRunHasNoExplanation() {
        let entries = [
            entry("r4", 0, "START RequestId: r4"),
            entry("r4", 1, #"{"nivel":"INFO","mensaje":"ejecución finalizada","fallos":0}"#)
        ]
        let run = LogAnalyzer.analyze(entries).first
        XCTAssertEqual(run?.status, .healthy)
        XCTAssertTrue(run?.warningMessages.isEmpty ?? false)
        XCTAssertNil(run?.statusExplanation)
    }

    func testLegacyRunWithoutWarningsDecodes() throws {
        // `ejecuciones.json` escrito antes de existir `warningMessages`.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(RobotRun.self, from: Data("""
        {"id":"x","requestID":"x","startedAt":"2024-02-01T00:00:00Z","status":"warning","periods":["2026-09"],
         "downloads":1,"totalKeys":2,"failures":0,"warningCount":1,"errorCount":0,
         "finished":true,"timedOut":false,"failureMessages":[],"isDerived":false}
        """.utf8))

        XCTAssertEqual(run.warningCount, 1)
        XCTAssertTrue(run.warningMessages.isEmpty)
    }

    private func entry(_ requestID: String, _ seconds: TimeInterval, _ message: String) -> LogEntry {
        let parsed = CloudWatchLogParser.parseJSONLine(message, fallbackDate: start.addingTimeInterval(seconds))
        return LogEntry(
            id: "\(requestID)-\(seconds)",
            timestamp: parsed?.timestamp ?? start.addingTimeInterval(seconds),
            level: parsed?.level ?? CloudWatchLogParser.inferLevel(message),
            message: parsed?.message ?? message,
            detail: parsed?.detail,
            raw: message,
            requestID: requestID,
            logStreamName: "stream-\(requestID)",
            metadata: parsed?.metadata ?? [:]
        )
    }
}

// MARK: - S3

final class S3ClientTests: XCTestCase {
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

    func testFindArtifactsBuildsTheRobotLayout() async throws {
        let listing = """
        <ListBucketResult>
          <Contents><Key>facturas-recibidas/produccion/2026/09/raw/0102/202609_factura.txt</Key></Contents>
          <Contents><Key>facturas-recibidas/produccion/2026/09/manifest/0102/202609_claves.json</Key></Contents>
        </ListBucketResult>
        """
        StubURLProtocol.configure { _ in (Self.response(200), Data(listing.utf8)) }

        let objects = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).findArtifacts(
            bucket: "facturas-recibidas",
            environment: "produccion",
            periods: ["2026-09"],
            ruc: "0102"
        )

        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects.first(where: { $0.kind == .txt })?.fileName, "202609_factura.txt")
        XCTAssertEqual(objects.first(where: { $0.kind == .json })?.fileName, "202609_claves.json")

        // SigV4 canonicaliza la consulta al firmar; `URL.query` la muestra
        // legible. Lo que importa es que el prefijo sea el de la carpeta real.
        let queries = StubURLProtocol.requestedURLs.compactMap(\.query)
        XCTAssertTrue(queries.contains { $0.contains("list-type=2") })
        XCTAssertTrue(
            queries.contains { $0.contains("prefix=facturas-recibidas/produccion/2026/09/raw/") },
            "Consultas: \(queries)"
        )
        XCTAssertTrue(
            queries.contains { $0.contains("prefix=facturas-recibidas/produccion/2026/09/manifest/") },
            "Consultas: \(queries)"
        )
    }

    func testFindArtifactsFiltersByRUC() async throws {
        let listing = """
        <ListBucketResult>
          <Contents><Key>facturas-recibidas/produccion/2026/09/raw/0102/a.txt</Key></Contents>
          <Contents><Key>facturas-recibidas/produccion/2026/09/raw/9999/otro.txt</Key></Contents>
        </ListBucketResult>
        """
        StubURLProtocol.configure { _ in (Self.response(200), Data(listing.utf8)) }

        let objects = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).findArtifacts(bucket: "b", environment: "produccion", periods: ["2026-09"], ruc: "0102")

        XCTAssertEqual(objects.map(\.key), ["facturas-recibidas/produccion/2026/09/raw/0102/a.txt"])
    }

    func testFindArtifactsWithoutPeriodsDoesNotCallAWS() async throws {
        let objects = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).findArtifacts(bucket: "b", environment: "produccion", periods: [], ruc: nil)

        XCTAssertTrue(objects.isEmpty)
        XCTAssertNil(StubURLProtocol.lastRequest)
    }

    func testGetObjectRequestsTheKeyPath() async throws {
        StubURLProtocol.configure { _ in (Self.response(200), Data("contenido".utf8)) }

        let data = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).getObject(S3Object(bucket: "facturas-recibidas", key: "carpeta/archivo.txt"))

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "contenido")
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.path,
            "/facturas-recibidas/carpeta/archivo.txt"
        )
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.host(), "s3.us-east-1.amazonaws.com")
    }

    func testGetObjectEncodesSpacesAndAccents() async throws {
        StubURLProtocol.configure { _ in (Self.response(200), Data()) }

        _ = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).getObject(S3Object(bucket: "b", key: "carpeta/factura año 2026.txt"))

        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.absoluteString,
            "https://s3.us-east-1.amazonaws.com/b/carpeta/factura%20a%C3%B1o%202026.txt"
        )
    }

    func testListQueryIncludesContinuationToken() {
        let query = S3Client.listQuery(prefix: "a/b", token: "tok")
        let names = query.map(\.name)
        XCTAssertEqual(names, ["list-type", "prefix", "max-keys", "continuation-token"])
        XCTAssertEqual(query.last?.value, "tok")
    }

    func testBucketPathIsEncoded() {
        XCTAssertEqual(S3Client.bucketPath("mi.bucket"), "/mi.bucket")
    }

    func testKindFollowsTheExtension() {
        XCTAssertEqual(S3Object(bucket: "b", key: "x/y/factura.TXT").kind, .txt)
        XCTAssertEqual(S3Object(bucket: "b", key: "x/y/claves.json").kind, .json)
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
        )!
    }
}
