import Foundation

/// Preferencias no secretas de la aplicación. Se guardan dentro del contenedor
/// de la app, en `Application Support/SriRobotMonitor/configuracion.json`.
struct RobotConfiguration: Codable, Sendable, Equatable {
    var region: String
    var functionName: String
    var logGroupName: String
    var notificationsEnabled: Bool
    var notifyWarnings: Bool
    var notifyOnStart: Bool = false
    var pollIntervalSeconds: Int
    var historyDays: Int
    /// Variables con las que se invoca al robot (la imagen sale de fábrica).
    var environment = RobotEnvironment()
    /// Bucket donde el robot deja los TXT y los JSON. Vacío = sin descargas.
    var bucketName: String = ""
    /// Nombre del ambiente que usa el robot en las rutas de S3
    /// (`facturas-recibidas/{ambiente}/...`).
    var environmentName: String = RobotConfiguration.defaultEnvironmentName

    static let defaultFunctionName = "sri-txt-robot"
    static let defaultRegion = "us-east-1"
    static let defaultEnvironmentName = "produccion"

    static let `default` = RobotConfiguration(
        region: defaultRegion,
        functionName: defaultFunctionName,
        logGroupName: "/aws/lambda/\(defaultFunctionName)",
        notificationsEnabled: true,
        notifyWarnings: true,
        pollIntervalSeconds: 4,
        historyDays: 45
    )

    static func defaultLogGroup(for functionName: String) -> String {
        let clean = functionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "" : "/aws/lambda/\(clean)"
    }

    static func normalized(_ configuration: RobotConfiguration) -> RobotConfiguration {
        var copy = configuration
        copy.region = copy.region.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.functionName = copy.functionName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.logGroupName = copy.logGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.logGroupName.isEmpty {
            copy.logGroupName = defaultLogGroup(for: copy.functionName)
        }
        copy.bucketName = copy.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.environmentName = copy.environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.environmentName.isEmpty {
            copy.environmentName = defaultEnvironmentName
        }
        copy.pollIntervalSeconds = min(max(copy.pollIntervalSeconds, 2), 60)
        copy.historyDays = min(max(copy.historyDays, 1), 365)
        copy.environment = RobotEnvironment.normalized(copy.environment)
        return copy
    }

    /// Las preferencias nuevas (entorno, aviso de inicio) pueden faltar en un
    /// JSON guardado con una versión anterior de la app.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decode(String.self, forKey: .region)
        functionName = try container.decode(String.self, forKey: .functionName)
        logGroupName = try container.decode(String.self, forKey: .logGroupName)
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        notifyWarnings = try container.decodeIfPresent(Bool.self, forKey: .notifyWarnings) ?? true
        notifyOnStart = try container.decodeIfPresent(Bool.self, forKey: .notifyOnStart) ?? false
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 4
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? 45
        environment = try container.decodeIfPresent(RobotEnvironment.self, forKey: .environment) ?? RobotEnvironment()
        bucketName = try container.decodeIfPresent(String.self, forKey: .bucketName) ?? ""
        environmentName = try container.decodeIfPresent(String.self, forKey: .environmentName)
            ?? RobotConfiguration.defaultEnvironmentName
    }

    init(
        region: String,
        functionName: String,
        logGroupName: String,
        notificationsEnabled: Bool,
        notifyWarnings: Bool,
        notifyOnStart: Bool = false,
        pollIntervalSeconds: Int,
        historyDays: Int,
        environment: RobotEnvironment = RobotEnvironment(),
        bucketName: String = "",
        environmentName: String = RobotConfiguration.defaultEnvironmentName
    ) {
        self.region = region
        self.functionName = functionName
        self.logGroupName = logGroupName
        self.notificationsEnabled = notificationsEnabled
        self.notifyWarnings = notifyWarnings
        self.notifyOnStart = notifyOnStart
        self.pollIntervalSeconds = pollIntervalSeconds
        self.historyDays = historyDays
        self.environment = environment
        self.bucketName = bucketName
        self.environmentName = environmentName
    }

    var isUsable: Bool {
        !region.isEmpty && !functionName.isEmpty && !logGroupName.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case region, functionName, logGroupName, notificationsEnabled, notifyWarnings
        case notifyOnStart, pollIntervalSeconds, historyDays, environment, bucketName, environmentName
    }

    var consoleURL: URL? {
        let group = logGroupName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? logGroupName
        let raw = "https://console.aws.amazon.com/cloudwatch/home?region=\(region)#logsV2:log-groups/log-group/\(group)"
        return URL(string: raw)
    }
}

/// Regiones habituales. El campo también acepta una región escrita a mano.
enum AWSRegions {
    static let common: [String] = [
        "us-east-1",
        "us-east-2",
        "us-west-1",
        "us-west-2",
        "ca-central-1",
        "sa-east-1",
        "eu-west-1",
        "eu-west-2",
        "eu-west-3",
        "eu-central-1",
        "eu-north-1",
        "eu-south-1",
        "ap-south-1",
        "ap-southeast-1",
        "ap-southeast-2",
        "ap-northeast-1",
        "ap-northeast-2",
        "ap-northeast-3",
        "ap-south-2",
        "ap-southeast-4",
        "me-south-1",
        "af-south-1"
    ]
}

/// Borrador editable de la pantalla de configuración inicial y revalidación.
struct AWSSetupDraft: Sendable, Equatable, Codable {
    var region: String = RobotConfiguration.defaultRegion
    var functionName: String = RobotConfiguration.defaultFunctionName
    var logGroupName: String = RobotConfiguration.defaultLogGroup(for: RobotConfiguration.defaultFunctionName)
    var accessKeyID: String = ""
    var secretAccessKey: String = ""
    var sessionToken: String = ""
    var environment = RobotEnvironment()
    var bucketName: String = ""
    var environmentName: String = RobotConfiguration.defaultEnvironmentName

    init() {}

    init(
        region: String,
        functionName: String,
        logGroupName: String,
        accessKeyID: String = "",
        secretAccessKey: String = "",
        sessionToken: String = "",
        environment: RobotEnvironment = RobotEnvironment(),
        bucketName: String = "",
        environmentName: String = RobotConfiguration.defaultEnvironmentName
    ) {
        self.region = region
        self.functionName = functionName
        self.logGroupName = logGroupName
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.environment = environment
        self.bucketName = bucketName
        self.environmentName = environmentName
    }

    /// El borrador que se guarda en disco no tiene secretos; al leerlo, los
    /// campos ausentes vuelven a su valor por defecto.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? RobotConfiguration.defaultRegion
        functionName = try container.decodeIfPresent(String.self, forKey: .functionName)
            ?? RobotConfiguration.defaultFunctionName
        logGroupName = try container.decodeIfPresent(String.self, forKey: .logGroupName)
            ?? RobotConfiguration.defaultLogGroup(for: functionName)
        accessKeyID = try container.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        secretAccessKey = try container.decodeIfPresent(String.self, forKey: .secretAccessKey) ?? ""
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
        environment = try container.decodeIfPresent(RobotEnvironment.self, forKey: .environment) ?? RobotEnvironment()
    }

    var credentials: AWSCredentials {
        AWSCredentials(
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionToken: sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    var hasCredentials: Bool {
        !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var configuration: RobotConfiguration {
        RobotConfiguration.normalized(
            RobotConfiguration(
                region: region,
                functionName: functionName,
                logGroupName: logGroupName,
                notificationsEnabled: true,
                notifyWarnings: true,
                pollIntervalSeconds: RobotConfiguration.default.pollIntervalSeconds,
                historyDays: RobotConfiguration.default.historyDays,
                environment: environment,
                bucketName: bucketName,
                environmentName: environmentName
            )
        )
    }

    static func from(configuration: RobotConfiguration, credentials: AWSCredentials?) -> AWSSetupDraft {
        AWSSetupDraft(
            region: configuration.region,
            functionName: configuration.functionName,
            logGroupName: configuration.logGroupName,
            accessKeyID: credentials?.accessKeyID ?? "",
            secretAccessKey: credentials?.secretAccessKey ?? "",
            sessionToken: credentials?.sessionToken ?? "",
            environment: configuration.environment,
            bucketName: configuration.bucketName,
            environmentName: configuration.environmentName
        )
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
