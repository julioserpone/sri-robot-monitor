import Foundation

/// Variables de entorno con las que la app invoca al robot cuando trabaja con
/// la imagen **genérica** publicada por `sri-txt-robot`.
///
/// La app no guarda estos valores en `configuracion.json`: viajan al Llavero
/// junto con las credenciales de AWS, porque la clave del portal del SRI y la
/// de anti-captcha son secretos. Al invocar se envían en el campo
/// `environment` (payload en modo `tail`), y el robot las aplica a su propio
/// `os.environ` durante la ejecución, sin tocar la configuración de la función.
struct RobotEnvironment: Codable, Sendable, Equatable {
    /// Nombre de la variable con la clave del portal. La imagen lee
    /// `SRI_PASSWORD` cuando `robots.yaml` declara `password_env: SRI_PASSWORD`.
    static let portalPasswordVariable = "SRI_PASSWORD"
    /// Clave de anti-captcha: `captcha.api_key_env` apunta aquí en la imagen.
    static let anticaptchaVariable = "ANTICAPTCHA_API_KEY"

    /// Clave del portal del contribuyente (RUC + dígito verificador). Vacía en
    /// las ejecuciones que no la necesiten o que usen el perfil caliente.
    var portalPassword: String = ""
    /// Clave de anti-captcha. Es el respaldo cuando el navegador no resuelve
    /// el reCAPTCHA.
    var anticaptchaKey: String = ""
    /// `portal.perfil_dir` dentro del contenedor, si la imagen trae un perfil
    /// calentado distinto al horneado por defecto.
    var profileDirectory: String = ""

    var isConfigured: Bool {
        isPortalPasswordSet || isAnticaptchaKeySet || !profileDirectory.isEmpty
    }

    /// Vacío equivale a "no configurado" después de normalizar.
    var isPortalPasswordSet: Bool { !portalPassword.isEmpty }
    var isAnticaptchaKeySet: Bool { !anticaptchaKey.isEmpty }

    /// Evento que consume la app para el modo `tail`.
    static let warmProfileClaim = "perfil caliente"

    /// Variables que se envían a AWS. Nunca incluye valores vacíos para no
    /// sobrescribir la configuración de la imagen con cadenas vacías.
    func variables() -> [String: String] {
        var result: [String: String] = [:]
        if !portalPassword.isEmpty {
            result[Self.portalPasswordVariable] = portalPassword
        }
        if !anticaptchaKey.isEmpty {
            result[Self.anticaptchaVariable] = anticaptchaKey
        }
        if !profileDirectory.isEmpty {
            result["SRI_PERFIL_DIR"] = profileDirectory
        }
        return result
    }

    /// La función de Lambda admite como máximo 4 KB de entorno por invocación.
    var estimatedBytes: Int {
        variables().reduce(0) { partial, item in
            partial + item.key.utf8.count + item.value.utf8.count + 4
        }
    }

    var exceedsInvocationLimit: Bool {
        estimatedBytes > 3_800
    }

    static func normalized(_ value: RobotEnvironment) -> RobotEnvironment {
        var copy = value
        copy.portalPassword = copy.portalPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.anticaptchaKey = copy.anticaptchaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.profileDirectory = copy.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

/// Todo lo que la app guarda en el Llavero bajo una sola entrada: las claves
/// de AWS (siempre) y los secretos del robot (opcionales).
struct StoredSecrets: Codable, Sendable, Equatable {
    var credentials: AWSCredentials
    var environment: RobotEnvironment = RobotEnvironment()

    var environmentIsComplete: Bool {
        !environment.portalPassword.isEmpty && !environment.anticaptchaKey.isEmpty
    }
}
