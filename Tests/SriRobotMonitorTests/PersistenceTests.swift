import XCTest
@testable import SriRobotMonitor

/// Pruebas de la persistencia local dentro de la app. Se usa una carpeta
/// temporal para no tocar `Application Support` ni el Llavero real.
final class AppPersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SriRobotMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testConfigurationRoundTrip() async throws {
        let persistence = AppPersistence(directory: directory)
        var config = RobotConfiguration.default
        config.functionName = "robot-pruebas"
        config.environment = RobotEnvironment(portalPassword: "p", anticaptchaKey: "a")

        try await persistence.saveConfiguration(config)
        let loaded = await persistence.loadConfiguration()

        XCTAssertEqual(loaded.functionName, "robot-pruebas")
        XCTAssertEqual(loaded.environment.anticaptchaKey, "a")
    }

    func testRunsAreTrimmedToOneHundred() async throws {
        let persistence = AppPersistence(directory: directory)
        let runs = (0..<130).map { index in
            RobotRun(
                id: "r\(index)",
                requestID: "r\(index)",
                startedAt: Date(timeIntervalSince1970: Double(index)),
                endedAt: nil,
                durationMilliseconds: nil,
                status: .healthy,
                periods: ["2026-09"],
                environment: nil,
                ruc: nil,
                downloads: 0,
                totalKeys: 0,
                failures: 0,
                warningCount: 0,
                errorCount: 0,
                finished: true,
                timedOut: false,
                failureMessages: [],
                logStreamName: nil,
                isDerived: false
            )
        }

        try await persistence.saveRuns(runs)
        let loaded = await persistence.loadRuns()
        XCTAssertEqual(loaded.count, 100)
    }

    func testSetupDraftNeverWritesSecrets() async throws {
        let persistence = AppPersistence(directory: directory)
        var draft = AWSSetupDraft()
        draft.region = "us-east-1"
        draft.accessKeyID = "AKIAEXAMPLE"
        draft.secretAccessKey = "super-secreto"
        draft.environment = RobotEnvironment(portalPassword: "clave-secreta-del-portal", anticaptchaKey: "captcha")

        try await persistence.saveSetupDraft(draft)
        let raw = try String(
            contentsOf: directory.appendingPathComponent("onboarding.json"),
            encoding: .utf8
        )

        XCTAssertFalse(raw.contains("super-secreto"))
        XCTAssertFalse(raw.contains("clave-secreta-del-portal"))
        XCTAssertTrue(raw.contains("AKIAEXAMPLE"))
        let restored = await persistence.loadSetupDraft()
        XCTAssertEqual(restored?.region, "us-east-1")
    }

    func testClearHistoryKeepsConfiguration() async throws {
        let persistence = AppPersistence(directory: directory)
        try await persistence.saveConfiguration(.default)
        try await persistence.saveLogs([
            LogEntry(id: "1", timestamp: Date(), level: .info, message: "hola", detail: nil, raw: "hola")
        ])

        try await persistence.clearHistory()

        let logs = await persistence.loadLogs()
        let configuration = await persistence.loadConfiguration()
        XCTAssertTrue(logs.isEmpty)
        XCTAssertEqual(configuration.region, RobotConfiguration.default.region)
    }

    func testDirectoryIsCreatedAtInit() {
        let nested = directory.appendingPathComponent("a/b/c", isDirectory: true)
        _ = AppPersistence(directory: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
