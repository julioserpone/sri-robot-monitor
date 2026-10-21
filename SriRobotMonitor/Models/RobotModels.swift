import Foundation

/// Estado operativo del robot, tal como lo resume el último registro de Lambda.
enum RobotStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case running
    case healthy
    case warning
    case error

    var title: String {
        switch self {
        case .unknown: "Sin datos"
        case .running: "En ejecución"
        case .healthy: "Operativo"
        case .warning: "Con advertencias"
        case .error: "Con errores"
        }
    }

    var shortTitle: String {
        switch self {
        case .unknown: "Desconocido"
        case .running: "Ejecutando"
        case .healthy: "Operativo"
        case .warning: "Advertencia"
        case .error: "Error"
        }
    }

    /// Qué significa cada color del LED, para lectores de pantalla y tooltips.
    var ledCaption: String {
        switch self {
        case .unknown: "Sin datos todavía"
        case .running: "Ejecución en curso"
        case .healthy: "Última ejecución correcta"
        case .warning: "Advertencias en la última ejecución"
        case .error: "Falló la última ejecución"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: "questionmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// El LED nunca debe transmitir calma si la última lectura falló.
    var isProblem: Bool {
        self == .error
    }
}

/// Nivel normalizado de una línea de CloudWatch Logs.
enum LogLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case system
    case debug
    case info
    case warning
    case error

    var title: String {
        switch self {
        case .system: "Sistema"
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var sortOrder: Int {
        switch self {
        case .system: 0
        case .debug: 1
        case .info: 2
        case .warning: 3
        case .error: 4
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    static func from(_ raw: String) -> LogLevel {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ERROR", "CRITICAL", "FATAL", "SEVERE":
            .error
        case "WARNING", "WARN":
            .warning
        case "DEBUG", "TRACE":
            .debug
        case "INFO", "NOTICE":
            .info
        default:
            .info
        }
    }
}

/// Una línea de log ya normalizada, con independencia del formato de AWS.
struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let level: LogLevel
    let message: String
    let detail: String?
    let raw: String
    let requestID: String?
    let logStreamName: String?
    let metadata: [String: String]

    init(
        id: String,
        timestamp: Date,
        level: LogLevel,
        message: String,
        detail: String? = nil,
        raw: String? = nil,
        requestID: String? = nil,
        logStreamName: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.detail = detail
        self.raw = raw ?? message
        self.requestID = requestID
        self.logStreamName = logStreamName
        self.metadata = metadata
    }

    var shortTime: String {
        timestamp.formatted(date: .omitted, time: .standard)
    }

    var timeWithDay: String {
        timestamp.formatted(date: .abbreviated, time: .standard)
    }
}

/// Resumen de una invocación de Lambda reconstruido a partir de sus logs.
struct RobotRun: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let requestID: String
    var startedAt: Date
    var endedAt: Date?
    var durationMilliseconds: Int?
    var status: RobotStatus
    var periods: [String]
    var environment: String?
    var ruc: String?
    var downloads: Int
    var totalKeys: Int
    var failures: Int
    var warningCount: Int
    var errorCount: Int
    var finished: Bool
    var timedOut: Bool
    var failureMessages: [String]
    var logStreamName: String?
    var isDerived: Bool

    var durationText: String {
        if let durationMilliseconds {
            let seconds = Double(durationMilliseconds) / 1_000
            if seconds < 60 {
                return String(format: "%.1f s", seconds)
            }
            let minutes = Int(seconds) / 60
            let remainder = Int(seconds) % 60
            return "\(minutes) min \(remainder) s"
        }
        guard let endedAt else { return "—" }
        return Self.format(duration: endedAt.timeIntervalSince(startedAt))
    }

    var periodText: String {
        periods.isEmpty ? "Mes configurado" : periods.joined(separator: ", ")
    }

    var subtitle: String {
        var parts: [String] = []
        if let environment { parts.append(environment) }
        if let ruc { parts.append("RUC \(ruc)") }
        parts.append(periodText)
        return parts.joined(separator: " · ")
    }

    private static func format(duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1f s", duration)
        }
        let minutes = Int(duration) / 60
        let remainder = Int(duration) % 60
        return "\(minutes) min \(remainder) s"
    }
}

/// Cuerpo que se envía a la función de Lambda.
///
/// `environment` solo viaja con el payload en modo `tail`: el robot lo aplica
/// a su propio entorno durante la ejecución, sin que la app tenga que cambiar
/// la configuración persistente de la función.
struct RobotInvocationPayload: Codable, Sendable, Equatable {
    var periodos: [String]
    var tipos: [String]?
    var forzar: Bool?
    var environment: [String: String]?

    init(
        periodos: [String],
        tipos: [String]? = nil,
        forzar: Bool? = nil,
        environment: [String: String]? = nil
    ) {
        self.periodos = periodos
        self.tipos = tipos
        self.forzar = forzar
        self.environment = environment
    }
}

/// Modo de invocación que entiende la imagen del robot.
///
/// - `event` (por defecto): dispara y olvida. Lambda responde en cuanto acepta
///   la ejecución, sin esperar al `REPORT`.
/// - `tail`: el router de la imagen mantiene la conexión hasta que el robot
///   termina y devuelve el resumen. Sirve para adjuntar variables de entorno
///   secretas sin reconfigurar la función (las env nuevas exigen `UpdateFunctionConfiguration`).
/// - `warm`: abre el perfil de Chrome del contenedor para que una persona
///   resuelva el reCAPTCHA una vez.
enum InvocationMode: String, Codable, Sendable, CaseIterable {
    case event
    case tail
}

/// Respuesta del modo `tail`, tal como la devuelve el router del robot.
struct RobotInvocationResult: Codable, Sendable, Equatable {
    var ok: Bool?
    var modo: String?
    var ejecutadoEn: String?
    var ambiente: String?
    var periodos: [String]?
    var descargas: Int?
    var claves: Int?
    var fallos: [String]?
    var error: String?
    var detalle: String?

    var failureCount: Int { fallos?.count ?? 0 }
    var succeeded: Bool { (ok ?? (error == nil)) && failureCount == 0 }
}

/// Resultado de validar credenciales y función contra AWS.
struct AWSSessionSummary: Codable, Sendable, Equatable {
    var account: String
    var arn: String
    var userID: String
    var validatedAt: Date
}
