import Foundation

/// Persistencia local de la app. En producción `directory` apunta al
/// contenedor de la app (`Application Support/SriRobotMonitor`); en pruebas se
/// inyecta una carpeta temporal.
actor AppPersistence {
    nonisolated let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            // Dentro del sandbox `applicationSupportDirectory` ya es
            // `~/Library/Containers/<bundle>/Data/Library/Application Support`.
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("SriRobotMonitor", isDirectory: true)
        }
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    var directoryPath: String {
        directory.path(percentEncoded: false)
    }

    var scriptsDirectory: URL {
        directory.appendingPathComponent("scripts", isDirectory: true)
    }

    func loadConfiguration() -> RobotConfiguration {
        read(RobotConfiguration.self, from: "configuracion.json") ?? .default
    }

    /// Borrador del onboarding: se guarda sin secretos para poder reanudar la
    /// configuración si la app se cierra a mitad de camino.
    func saveSetupDraft(_ draft: AWSSetupDraft) throws {
        var sanitized = draft
        sanitized.secretAccessKey = ""
        sanitized.sessionToken = ""
        sanitized.environment.portalPassword = ""
        sanitized.environment.anticaptchaKey = ""
        // Se escribe como diccionario: `JSONEncoder` no aplica las claves de
        // `CodingKeys` al codificar si no se declara `encode(to:)`.
        let object: [String: Any] = [
            "region": sanitized.region,
            "functionName": sanitized.functionName,
            "logGroupName": sanitized.logGroupName,
            "accessKeyID": sanitized.accessKeyID,
            "secretAccessKey": "",
            "sessionToken": "",
            "environment": [
                "portalPassword": "",
                "anticaptchaKey": "",
                "profileDirectory": sanitized.environment.profileDirectory
            ]
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("onboarding.json"), options: .atomic)
    }

    func loadSetupDraft() -> AWSSetupDraft? {
        read(AWSSetupDraft.self, from: "onboarding.json")
    }

    func clearSetupDraft() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("onboarding.json"))
    }

    func saveConfiguration(_ configuration: RobotConfiguration) throws {
        try write(configuration, to: "configuracion.json")
    }

    func loadCredentials() throws -> AWSCredentials? {
        try KeychainStore.load()
    }

    func loadEnvironment() throws -> RobotEnvironment {
        (try KeychainStore.loadEnvironment()) ?? RobotEnvironment()
    }

    func saveCredentials(_ credentials: AWSCredentials) throws {
        try KeychainStore.save(credentials)
    }

    /// Las claves de AWS y los secretos del robot comparten entrada del
    /// Llavero para que un restablecimiento no deje secretos huérfanos.
    func saveSecrets(_ credentials: AWSCredentials, environment: RobotEnvironment) throws {
        try KeychainStore.save(StoredSecrets(credentials: credentials, environment: environment))
    }

    func loadRuns() -> [RobotRun] {
        read([RobotRun].self, from: "ejecuciones.json") ?? []
    }

    func saveRuns(_ runs: [RobotRun]) throws {
        try write(Array(runs.prefix(100)), to: "ejecuciones.json")
    }

    func loadLogs() -> [LogEntry] {
        read([LogEntry].self, from: "registros.json") ?? []
    }

    func saveLogs(_ logs: [LogEntry]) throws {
        try write(Array(logs.suffix(2_000)), to: "registros.json")
    }

    func loadNotifiedRunIDs() -> [String] {
        read([String].self, from: "notificadas.json") ?? []
    }

    func saveNotifiedRunIDs(_ ids: [String]) throws {
        try write(Array(ids.suffix(200)), to: "notificadas.json")
    }

    func clearHistory() throws {
        for name in ["ejecuciones.json", "registros.json", "notificadas.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func resetAll() throws {
        try? FileManager.default.removeItem(at: directory)
        try KeychainStore.delete()
    }

    // MARK: - JSON

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
