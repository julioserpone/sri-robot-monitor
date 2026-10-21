import AppKit
import SwiftUI

struct RunsView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var selectedRun: RobotRun?

    private var successRate: String {
        let completed = engine.runs.filter(\.finished)
        guard !completed.isEmpty else { return "—" }
        let healthy = completed.filter { $0.status == .healthy || $0.status == .warning }.count
        return "\(Int((Double(healthy) / Double(completed.count)) * 100))%"
    }

    private var totalKeys: Int {
        engine.runs.reduce(0) { $0 + $1.totalKeys }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    MetricTile(
                        title: "Ejecuciones detectadas",
                        value: "\(engine.runs.count)",
                        caption: "Últimos \(engine.configuration.historyDays) días",
                        symbol: "clock.arrow.circlepath",
                        tint: Palette.blue
                    )
                    MetricTile(
                        title: "Tasa de éxito",
                        value: successRate,
                        caption: "Sin errores ni warnings",
                        symbol: "chart.line.uptrend.xyaxis",
                        tint: Palette.green
                    )
                    MetricTile(
                        title: "Claves acumuladas",
                        value: "\(totalKeys)",
                        caption: "En todas las ejecuciones",
                        symbol: "key.fill",
                        tint: Palette.amber
                    )
                    MetricTile(
                        title: "Fallos acumulados",
                        value: "\(engine.runs.reduce(0) { $0 + $1.failures })",
                        caption: "Reportados por el robot",
                        symbol: "exclamationmark.octagon.fill",
                        tint: Palette.red
                    )
                }

                if engine.runs.isEmpty {
                    GlassCard {
                        EmptyStateView(
                            symbol: "clock.badge.questionmark",
                            title: "Sin ejecuciones en el historial",
                            message: "El historial se reconstruye desde CloudWatch Logs. Relanza el robot o espera a la próxima ejecución programada."
                        )
                    }
                } else {
                    runsTable
                }
            }
            .padding(26)
        }
        .sheet(item: $selectedRun) { run in
            RunDetailView(run: run)
                .environment(engine)
        }
    }

    private var runsTable: some View {
        GlassCard(cornerRadius: 24, padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("ESTADO")
                        .frame(width: 104, alignment: .leading)
                    Text("INICIO")
                        .frame(width: 145, alignment: .leading)
                    Text("PERÍODO")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("TXT")
                        .frame(width: 44, alignment: .trailing)
                    Text("CLAVES")
                        .frame(width: 56, alignment: .trailing)
                    Text("DURACIÓN")
                        .frame(width: 72, alignment: .trailing)
                    Text("FALLOS")
                        .frame(width: 52, alignment: .trailing)
                    Spacer().frame(width: 12)
                }
                .font(.system(size: 8, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)

                Divider().overlay(.white.opacity(0.06))

                ForEach(engine.runs) { run in
                    Button {
                        selectedRun = run
                    } label: {
                        RunRow(run: run)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.04))
                }
            }
        }
    }
}

private struct RunRow: View {
    let run: RobotRun
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(run.status.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: run.status.color.opacity(0.7), radius: 4)
                Text(run.status.shortTitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(run.status.color)
            }
            .frame(width: 104, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, weight: .medium))
                Text(run.endedAt.map { "Fin \($0.formatted(date: .omitted, time: .shortened))" } ?? "En curso")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(width: 145, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(run.periodText)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text(run.subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(run.downloads)")
                .frame(width: 44, alignment: .trailing)
            Text("\(run.totalKeys)")
                .frame(width: 56, alignment: .trailing)
            Text(run.durationText)
                .frame(width: 72, alignment: .trailing)
            Text("\(run.failures)")
                .foregroundStyle(run.failures > 0 ? Palette.red : .white.opacity(0.55))
                .frame(width: 52, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.18))
                .frame(width: 12)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.78))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(hovering ? .white.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct RunDetailView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let run: RobotRun

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                StatusOrb(status: run.status, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.status.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(run.startedAt.formatted(date: .complete, time: .standard))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                StatusPill(status: run.status, compact: true)
            }
            .padding(22)

            Divider().overlay(.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        MiniStat(title: "Períodos", value: run.periodText)
                        MiniStat(title: "Duración", value: run.durationText)
                        MiniStat(title: "TXT", value: "\(run.downloads)")
                        MiniStat(title: "Claves", value: "\(run.totalKeys)")
                        MiniStat(title: "Fallos", value: "\(run.failures)", tint: run.failures > 0 ? Palette.red : .white)
                        MiniStat(title: "Warnings", value: "\(run.warningCount)", tint: run.warningCount > 0 ? Palette.amber : .white)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Detalle", symbol: "list.bullet.rectangle")
                        VStack(spacing: 7) {
                            KeyValueRow(key: "Request ID", value: run.requestID, monospaced: true)
                            KeyValueRow(key: "Ambiente", value: run.environment ?? "—")
                            KeyValueRow(key: "RUC", value: run.ruc ?? "—", monospaced: true)
                            KeyValueRow(key: "Inicio", value: run.startedAt.formatted(date: .abbreviated, time: .standard))
                            KeyValueRow(key: "Fin", value: run.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "En curso")
                            KeyValueRow(key: "Log stream", value: run.logStreamName ?? "—", monospaced: true)
                        }
                    }

                    if !run.failureMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(title: "Errores y fallos", symbol: "exclamationmark.triangle.fill")
                            ForEach(run.failureMessages, id: \.self) { message in
                                Text(message)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.red.opacity(0.9))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }

                    if run.status == .healthy {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Palette.green)
                            Text("Ejecución completada sin errores. El TXT y las claves quedaron en S3.")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(22)
            }

            Divider().overlay(.white.opacity(0.07))

            HStack {
                Button("Copiar RequestId") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.requestID, forType: .string)
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Spacer()

                Button("Cerrar") {
                    dismiss()
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    dismiss()
                    engine.selectedSection = .logs
                } label: {
                    Label("Ver registros", systemImage: "text.alignleft")
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.green)
                .controlSize(.small)
            }
            .padding(16)
        }
        .frame(width: 620, height: 600)
        .background(AuroraBackground())
    }
}
