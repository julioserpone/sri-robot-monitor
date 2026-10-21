import AppKit
import SwiftUI

struct LogsView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var query = ""
    @State private var levels: Set<LogLevel> = [.info, .warning, .error, .system]
    @State private var onlyLatestRun = false
    @State private var autoScroll = true

    private var filtered: [LogEntry] {
        var result = engine.logs

        if onlyLatestRun, let run = engine.latestRun {
            let start = run.startedAt.addingTimeInterval(-1)
            let end = run.endedAt?.addingTimeInterval(2) ?? Date().addingTimeInterval(5)
            result = result.filter { $0.timestamp >= start && $0.timestamp <= end }
        }

        result = result.filter { levels.contains($0.level) }

        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(term)
                    || ($0.detail?.localizedCaseInsensitiveContains(term) ?? false)
                    || ($0.requestID?.localizedCaseInsensitiveContains(term) ?? false)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(.white.opacity(0.06))
            content
        }
        .background(.clear)
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                    TextField("Buscar en los registros", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
                .frame(maxWidth: 330)

                Spacer(minLength: 4)

                Toggle(isOn: $onlyLatestRun) {
                    Text("Última ejecución")
                        .font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Toggle(isOn: $autoScroll) {
                    Text("Auto-scroll")
                        .font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button {
                    if engine.isLive {
                        engine.stopMonitoring()
                    } else {
                        engine.startMonitoring()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(engine.isLive ? Palette.green : Palette.amber)
                            .frame(width: 6, height: 6)
                        Text(engine.isLive ? "En vivo" : "Pausado")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(engine.isLive ? "Pausar la lectura de CloudWatch" : "Reanudar la lectura de CloudWatch")

                Button {
                    if let url = engine.configuration.consoleURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Abrir CloudWatch en el navegador")
            }

            HStack(spacing: 6) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    FilterPill(
                        level: level,
                        isOn: levels.contains(level)
                    ) {
                        if levels.contains(level) {
                            levels.remove(level)
                        } else {
                            levels.insert(level)
                        }
                    }
                }
                Spacer()
                Text("\(filtered.count) líneas")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                Text("·")
                    .foregroundStyle(.white.opacity(0.18))
                Text(engine.configuration.logGroupName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            EmptyStateView(
                symbol: "text.alignleft",
                title: engine.logs.isEmpty ? "Sin registros todavía" : "Ningún registro coincide",
                message: engine.logs.isEmpty
                    ? (engine.logGroupMissing
                        ? "El log group aún no tiene eventos. Se llenará en la próxima ejecución del robot."
                        : "Los registros de Lambda aparecerán aquí en tiempo real.")
                    : "Prueba con otro término o activa más niveles de log."
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            LogRowView(entry: entry)
                                .id(entry.id)
                            Divider().overlay(.white.opacity(0.035))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                .onChange(of: filtered.count) { _, _ in
                    guard autoScroll, let last = filtered.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if autoScroll, let last = filtered.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct FilterPill: View {
    let level: LogLevel
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? level.color : .white.opacity(0.18))
                    .frame(width: 5, height: 5)
                Text(level.title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isOn ? level.color : .white.opacity(0.34))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isOn ? level.color.opacity(0.10) : .white.opacity(0.025),
                in: .capsule
            )
            .overlay {
                Capsule().strokeBorder(
                    isOn ? level.color.opacity(0.22) : .white.opacity(0.06),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
    }
}

struct LogRowView: View {
    let entry: LogEntry
    var compact = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            Text(entry.shortTime)
                .font(.system(size: compact ? 8 : 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.30))
                .frame(width: compact ? 54 : 64, alignment: .leading)
                .padding(.top, 1)

            LevelBadge(level: entry.level)
                .frame(width: compact ? 48 : 54, alignment: .leading)
                .padding(.top, 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: compact ? 9.5 : 10.5, design: .monospaced))
                    .foregroundStyle(entry.level == .error ? Palette.red.opacity(0.92) : .white.opacity(0.82))
                    .lineLimit(compact ? 1 : 6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !compact, let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            if let requestID = entry.requestID, !compact {
                Text(String(requestID.prefix(8)))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.20))
                    .padding(.top, 2)
            }

            if hovering, !compact {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.raw, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help("Copiar línea")
            }
        }
        .padding(.vertical, compact ? 5 : 6)
        .padding(.horizontal, compact ? 2 : 6)
        .background(hovering && !compact ? .white.opacity(0.025) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copiar línea") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.raw, forType: .string)
            }
            if let requestID = entry.requestID {
                Button("Copiar RequestId") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(requestID, forType: .string)
                }
            }
        }
    }
}
