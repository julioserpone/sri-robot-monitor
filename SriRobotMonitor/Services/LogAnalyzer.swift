import Foundation

/// Reconstruye ejecuciones completas a partir de las líneas de CloudWatch.
///
/// Lambda mezcla líneas de plataforma (`START`, `END`, `REPORT`) con el JSON
/// estructurado del robot. El analizador agrupa por `RequestId`, cuenta
/// descargas, claves y fallos, y decide el color del LED:
///
/// - verde: terminó y el resumen no reporta fallos;
/// - naranja: terminó, pero hubo warnings;
/// - rojo: errores, fallos del resumen, timeout o ejecución abortada;
/// - azul: sigue en curso.
enum LogAnalyzer {
    static let staleRunThreshold: TimeInterval = 25 * 60

    static func analyze(_ entries: [LogEntry], now: Date = Date()) -> [RobotRun] {
        let ordered = entries.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }

        var runs: [String: MutableRun] = [:]
        var streamCurrent: [String: String] = [:]
        var fallbackCurrent: String?

        for entry in ordered {
            if entry.message.hasPrefix("START RequestId:"), let id = entry.requestID {
                var run = runs[id] ?? MutableRun(requestID: id, startedAt: entry.timestamp)
                run.startedAt = min(run.startedAt, entry.timestamp)
                run.logStreamName = entry.logStreamName ?? run.logStreamName
                runs[id] = run
                if let stream = entry.logStreamName {
                    streamCurrent[stream] = id
                }
                fallbackCurrent = id
                continue
            }

            if entry.message.hasPrefix("REPORT RequestId:"), let id = entry.requestID {
                if var run = runs[id] {
                    run.reportSeen = true
                    run.finished = true
                    run.durationMilliseconds = CloudWatchLogParser.durationMilliseconds(in: entry.message)
                    if let duration = run.durationMilliseconds {
                        run.endedAt = run.startedAt.addingTimeInterval(Double(duration) / 1_000)
                    } else {
                        run.endedAt = entry.timestamp
                    }
                    if let stream = entry.logStreamName, streamCurrent[stream] == id {
                        streamCurrent.removeValue(forKey: stream)
                    }
                    runs[id] = run
                }
                if fallbackCurrent == id { fallbackCurrent = nil }
                continue
            }

            if entry.message.hasPrefix("END RequestId:"), let id = entry.requestID {
                if var run = runs[id] {
                    if run.endedAt == nil { run.endedAt = entry.timestamp }
                    runs[id] = run
                }
                continue
            }

            var requestID = entry.requestID
            if requestID == nil, let stream = entry.logStreamName {
                requestID = streamCurrent[stream]
            }
            if requestID == nil {
                requestID = fallbackCurrent
            }

            if requestID == nil, shouldStartDerivedRun(entry) {
                let derivedID = "derived-\(entry.logStreamName ?? entry.id)"
                var run = runs[derivedID] ?? MutableRun(
                    requestID: derivedID,
                    startedAt: entry.timestamp,
                    isDerived: true
                )
                run.startedAt = min(run.startedAt, entry.timestamp)
                run.logStreamName = entry.logStreamName ?? run.logStreamName
                run.absorb(entry)
                runs[derivedID] = run
                if let stream = entry.logStreamName {
                    streamCurrent[stream] = derivedID
                }
                fallbackCurrent = derivedID
                continue
            }

            guard let requestID, var run = runs[requestID] else { continue }
            run.absorb(entry)
            runs[requestID] = run
        }

        return runs.values
            .map { $0.finalize(now: now) }
            .sorted { lhs, rhs in
                lhs.startedAt == rhs.startedAt ? lhs.requestID > rhs.requestID : lhs.startedAt > rhs.startedAt
            }
    }

    private static func shouldStartDerivedRun(_ entry: LogEntry) -> Bool {
        if entry.level == .error || entry.level == .warning {
            return true
        }
        return entry.metadata["periodos"] != nil
            || entry.metadata["fallos"] != nil
            || entry.message == "iniciando ejecución del robot"
            || entry.message == "ejecución finalizada"
            || entry.message == "TXT descargado"
    }
}

private struct MutableRun {
    let requestID: String
    var startedAt: Date
    var endedAt: Date?
    var logStreamName: String?
    var isDerived: Bool
    var durationMilliseconds: Int?
    var reportSeen = false
    var finalSummarySeen = false
    var finished = false
    var timedOut = false
    var downloads = 0
    var totalKeys = 0
    var failures = 0
    var warningCount = 0
    var errorCount = 0
    var periods: [String] = []
    var environment: String?
    var ruc: String?
    var failureMessages: [String] = []

    init(requestID: String, startedAt: Date, isDerived: Bool = false) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.isDerived = isDerived
    }

    mutating func absorb(_ entry: LogEntry) {
        if entry.level == .warning {
            warningCount += 1
        }
        if entry.level == .error {
            errorCount += 1
            appendFailure(entry.message)
        }
        if entry.raw.uppercased().contains("TASK TIMED OUT") {
            timedOut = true
            appendFailure("La función agotó el tiempo máximo de Lambda.")
        }

        if let value = entry.metadata["ambiente"], !value.isEmpty {
            environment = value
        }
        if let value = entry.metadata["ruc"], !value.isEmpty {
            ruc = value
        }

        switch entry.message {
        case "iniciando ejecución del robot":
            if let raw = entry.metadata["periodos"] {
                appendPeriods(raw)
            }
        case "TXT descargado":
            downloads += 1
            if let raw = entry.metadata["claves"], let keys = Int(raw) {
                totalKeys += keys
            }
            if let period = entry.metadata["periodo"] {
                appendPeriod(period)
            }
        case "ejecución finalizada":
            finalSummarySeen = true
            finished = true
            endedAt = endedAt ?? entry.timestamp
            if let raw = entry.metadata["fallos"], let count = Int(raw) {
                failures = count
                if count > 0 {
                    appendFailure("El resumen de la ejecución reporta \(count) fallo(s).")
                }
            }
            if let raw = entry.metadata["periodos"] {
                appendPeriods(raw)
            }
        default:
            break
        }
    }

    func finalize(now: Date) -> RobotRun {
        var status: RobotStatus
        var messages = failureMessages

        if timedOut {
            status = .error
        } else if !finished {
            if now.timeIntervalSince(startedAt) > LogAnalyzer.staleRunThreshold {
                status = .error
                messages.append("La ejecución no terminó en el tiempo esperado.")
            } else {
                status = .running
            }
        } else if failures > 0 || errorCount > 0 || !finalSummarySeen {
            status = .error
            if !finalSummarySeen, messages.isEmpty {
                messages.append("La ejecución terminó sin escribir el resumen final.")
            }
        } else if warningCount > 0 {
            status = .warning
        } else if isDerived {
            status = .unknown
        } else {
            status = .healthy
        }

        if isDerived, !finished, status != .error {
            status = .unknown
        }

        let duration = durationMilliseconds
            ?? endedAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) }

        return RobotRun(
            id: requestID,
            requestID: requestID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: duration,
            status: status,
            periods: periods,
            environment: environment,
            ruc: ruc,
            downloads: downloads,
            totalKeys: totalKeys,
            failures: failures,
            warningCount: warningCount,
            errorCount: errorCount,
            finished: finished,
            timedOut: timedOut,
            failureMessages: Array(messages.prefix(8)),
            logStreamName: logStreamName,
            isDerived: isDerived
        )
    }

    private mutating func appendFailure(_ message: String) {
        guard failureMessages.count < 8 else { return }
        let clean = message.split(separator: "\n").first.map(String.init) ?? message
        if !failureMessages.contains(clean) {
            failureMessages.append(String(clean.prefix(500)))
        }
    }

    private mutating func appendPeriods(_ raw: String) {
        let cleaned = raw
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        for part in cleaned.split(separator: ",") {
            appendPeriod(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private mutating func appendPeriod(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !periods.contains(clean) else { return }
        periods.append(clean)
    }
}
