import Foundation

/// Período mensual que entiende el handler de Lambda (`YYYY-MM`).
struct Periodo: Identifiable, Hashable, Codable, Sendable {
    let year: Int
    let month: Int

    var id: String { key }

    var key: String {
        String(format: "%04d-%02d", year, month)
    }

    var shortLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_EC")
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date).capitalized
    }

    var longLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_EC")
        formatter.dateFormat = "MMMM 'de' yyyy"
        return formatter.string(from: date).capitalized
    }

    var date: Date {
        Calendar.sri.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    static func previousClosedMonth(
        now: Date = Date(),
        calendar: Calendar = .sri
    ) -> Periodo {
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? 2026
        let month = components.month ?? 1
        if month == 1 {
            return Periodo(year: year - 1, month: 12)
        }
        return Periodo(year: year, month: month - 1)
    }

    /// Devuelve los últimos `count` meses, del más reciente al más antiguo.
    static func recent(
        count: Int,
        now: Date = Date(),
        calendar: Calendar = .sri
    ) -> [Periodo] {
        guard count > 0 else { return [] }
        let start = previousClosedMonth(now: now, calendar: calendar)
        var result: [Periodo] = []
        var current = start
        for _ in 0..<count {
            result.append(current)
            current = current.previous
        }
        return result
    }

    var previous: Periodo {
        if month == 1 {
            return Periodo(year: year - 1, month: 12)
        }
        return Periodo(year: year, month: month - 1)
    }

    var next: Periodo {
        if month == 12 {
            return Periodo(year: year + 1, month: 1)
        }
        return Periodo(year: year, month: month + 1)
    }

    static func fromKey(_ key: String) -> Periodo? {
        let parts = key.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month) else {
            return nil
        }
        return Periodo(year: year, month: month)
    }
}

extension Calendar {
    static var sri: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "es_EC")
        calendar.timeZone = TimeZone(identifier: "America/Guayaquil") ?? .current
        return calendar
    }
}
