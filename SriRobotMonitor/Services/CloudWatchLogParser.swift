import Foundation

/// Convierte los eventos crudos de CloudWatch en líneas de log utilizables.
enum CloudWatchLogParser {
    static func parse(event: CloudWatchLogEvent) -> LogEntry {
        let message = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDate = event.date

        if let parsed = parseJSONLine(message, fallbackDate: fallbackDate) {
            return LogEntry(
                id: event.eventId,
                timestamp: parsed.timestamp,
                level: parsed.level,
                message: parsed.message,
                detail: parsed.detail,
                raw: message,
                requestID: requestID(in: message),
                logStreamName: event.logStreamName,
                metadata: parsed.metadata
            )
        }

        let level = inferLevel(message)
        return LogEntry(
            id: event.eventId,
            timestamp: fallbackDate,
            level: level,
            message: message,
            detail: nil,
            raw: message,
            requestID: requestID(in: message),
            logStreamName: event.logStreamName
        )
    }

    static func parseJSONLine(_ message: String, fallbackDate: Date) -> ParsedJSONLog? {
        guard message.hasPrefix("{"), let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let timestamp = (object["ts"] as? String).flatMap(parseISODate) ?? fallbackDate
        let level = LogLevel.from(object["nivel"] as? String ?? "INFO")
        var text = (object["mensaje"] as? String) ?? message
        var metadata: [String: String] = [:]

        for (key, value) in object {
            guard !["ts", "nivel", "mensaje", "logger"].contains(key) else { continue }
            metadata[key] = describe(value)
        }

        if let exception = object["excepcion"] as? String, !exception.isEmpty {
            text += "\n\(exception)"
        }

        let detail = metadata
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")

        return ParsedJSONLog(
            timestamp: timestamp,
            level: level,
            message: text,
            detail: detail.isEmpty ? nil : detail,
            metadata: metadata
        )
    }

    static func inferLevel(_ message: String) -> LogLevel {
        let upper = message.uppercased()
        if upper.contains("[ERROR]") || upper.contains("TASK TIMED OUT") || upper.contains("TRACEBACK")
            || upper.hasPrefix("ERROR") {
            return .error
        }
        if upper.contains("[WARNING]") || upper.hasPrefix("WARNING") {
            return .warning
        }
        return .system
    }

    static func requestID(in message: String) -> String? {
        guard let range = message.range(of: "RequestId: ") else { return nil }
        let remainder = message[range.upperBound...]
        return remainder.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    static func durationMilliseconds(in message: String) -> Int? {
        guard let range = message.range(of: "Duration: ") else { return nil }
        let remainder = message[range.upperBound...]
        guard let token = remainder.split(whereSeparator: { $0.isWhitespace }).first,
              let value = Double(token) else { return nil }
        return Int(value.rounded())
    }

    /// CloudWatch devuelve las marcas de tiempo en milisegundos.
    static func date(fromMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    /// ISO-8601 con zona `Z` o con desplazamiento (`+00:00`) y segundos
    /// fraccionarios de hasta 6 dígitos, como los escribe el robot.
    static func parseISODate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let date = basic.date(from: value) {
            return date
        }
        // `ISO8601DateFormatter` rechaza microsegundos o `+00:00` en algunas
        // configuraciones regionales; se normaliza a milisegundos.
        guard var normalized = parseWithOffsets(value) else { return nil }
        normalized = normalized.replacingOccurrences(of: "+00:00", with: "Z")
        return fractional.date(from: normalized) ?? basic.date(from: normalized)
    }

    private static func parseWithOffsets(_ value: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) {
                let output = ISO8601DateFormatter()
                output.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return output.string(from: date)
            }
        }
        return nil
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let array as [Any]:
            return array.map(describe).joined(separator: ", ")
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().map { "\($0)=\(describe(dictionary[$0] ?? ""))" }.joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }
}

struct ParsedJSONLog: Equatable {
    var timestamp: Date
    var level: LogLevel
    var message: String
    var detail: String?
    var metadata: [String: String]
}
