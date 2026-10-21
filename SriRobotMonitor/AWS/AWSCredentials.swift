import Foundation

/// Credenciales estáticas (o temporales) de AWS. Se guardan en el Llavero,
/// nunca en el JSON de preferencias.
struct AWSCredentials: Codable, Sendable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?

    var isComplete: Bool {
        !accessKeyID.isEmpty && !secretAccessKey.isEmpty
    }

    var maskedAccessKeyID: String {
        guard accessKeyID.count > 8 else { return accessKeyID }
        return "\(accessKeyID.prefix(4))••••••••\(accessKeyID.suffix(4))"
    }
}

struct CallerIdentity: Codable, Sendable, Equatable {
    var account: String
    var arn: String
    var userID: String

    var displayName: String {
        if let slash = arn.split(separator: "/").last {
            return String(slash)
        }
        return arn
    }
}

struct LambdaFunctionInfo: Codable, Sendable, Equatable {
    var functionName: String
    var state: String
    var lastUpdateStatus: String?
    var lastModified: String?
    var memorySize: Int?
    var timeout: Int?
    var codeSize: Int?
    var runtime: String?

    var isActive: Bool {
        state.caseInsensitiveCompare("Active") == .orderedSame
    }

    var healthText: String {
        if isActive {
            return lastUpdateStatus?.caseInsensitiveCompare("Successful") == .orderedSame ? "Activa" : state
        }
        return state
    }
}

struct AWSValidation: Sendable, Equatable {
    var identity: CallerIdentity
    var function: LambdaFunctionInfo
    var validatedAt: Date
}
