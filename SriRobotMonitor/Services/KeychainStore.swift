import Foundation
import LocalAuthentication
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
///
/// Cada lectura del Llavero puede mostrar el diálogo del sistema pidiendo la
/// contraseña de inicio de sesión ("SriRobotMonitor wants to use your
/// confidential information"). Leerlo en cada ciclo del motor lanzaba ese
/// diálogo varias veces por minuto y "Always allow" no siempre se respeta.
/// Por eso los secretos se leen una sola vez por lanzamiento y se cachean aquí:
/// cualquier guardado actualiza la caché y el resto de lecturas son en memoria.
enum KeychainStore {
    static let service = "com.julioserpone.sri-robot-monitor"
    static let account = "aws-credentials"

    /// Estado mutable de la caché, protegido por `lock`.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var secrets: StoredSecrets??
        /// Contexto reutilizable para el diálogo del sistema. `LAContext` no es
        /// `Sendable`, por eso vive aquí y se accede siempre con `lock`.
        let context = LAContext()
    }

    private static let cache = Cache()

    private static func authenticationContext() -> LAContext {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        cache.context.interactionNotAllowed = false
        return cache.context
    }

    static func save(_ secrets: StoredSecrets) throws {
        let data = Data(try JSONEncoder().encode(secrets))
        try write(data)
        cache.lock.lock()
        cache.secrets = .some(secrets)
        cache.lock.unlock()
    }

    /// Devuelve los secretos sin volver a tocar el Llavero si ya se leyeron en
    /// este lanzamiento.
    static func loadSecrets() throws -> StoredSecrets? {
        cache.lock.lock()
        let cached = cache.secrets
        cache.lock.unlock()
        if let cached {
            return cached
        }

        let secrets = try readSecretsFromKeychain()
        cache.lock.lock()
        cache.secrets = .some(secrets)
        cache.lock.unlock()
        return secrets
    }

    private static func readSecretsFromKeychain() throws -> StoredSecrets? {
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

        if status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private static func read() throws -> Data? {
        // Espera acotada: si el diálogo del sistema no se responde, devolvemos
        // `errSecInteractionNotAllowed` en lugar de bloquear la app.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: Self.authenticationContext()
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
        cache.lock.lock()
        cache.secrets = .some(nil)
        cache.lock.unlock()
    }

    /// Olvida la caché en memoria; la próxima lectura volverá al Llavero.
    static func invalidateCache() {
        cache.lock.lock()
        cache.secrets = nil
        cache.lock.unlock()
    }
}
