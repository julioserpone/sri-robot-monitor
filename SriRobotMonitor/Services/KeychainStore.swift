import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "código \(status)"
            return "No se pudo acceder al Llavero: \(message)"
        case .invalidData:
            return "Las credenciales guardadas en el Llavero no se pudieron leer."
        }
    }
}

/// Las claves de AWS y las del robot viven en el Llavero de macOS, ligadas a la
/// app. El resto de datos (preferencias, historial y logs) vive en su contenedor.
enum KeychainStore {
    static let service = "com.julioserpone.sri-robot-monitor"
    static let account = "aws-credentials"

    static func save(_ secrets: StoredSecrets) throws {
        try write(Data(try JSONEncoder().encode(secrets)))
    }

    static func loadSecrets() throws -> StoredSecrets? {
        guard let data = try read() else { return nil }
        if let secrets = try? JSONDecoder().decode(StoredSecrets.self, from: data) {
            return secrets
        }
        // Entrada escrita por una versión anterior de la app: solo AWS.
        guard let credentials = try? JSONDecoder().decode(AWSCredentials.self, from: data) else {
            throw KeychainError.invalidData
        }
        return StoredSecrets(credentials: credentials)
    }

    static func save(_ credentials: AWSCredentials) throws {
        let existing = (try? loadSecrets()?.environment) ?? RobotEnvironment()
        try save(StoredSecrets(credentials: credentials, environment: existing))
    }

    static func load() throws -> AWSCredentials? {
        try loadSecrets()?.credentials
    }

    static func loadEnvironment() throws -> RobotEnvironment? {
        try loadSecrets()?.environment
    }

    private static func write(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private static func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
