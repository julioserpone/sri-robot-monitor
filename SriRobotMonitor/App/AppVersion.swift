import Foundation

/// Versión que muestra la app. Un único punto de verdad para la barra lateral,
/// Ajustes y el pie de la página de bienvenida.
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
