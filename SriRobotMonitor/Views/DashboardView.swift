import SwiftUI

struct DashboardView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var showingInvoke = false
    @State private var dismissedError = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let connectionError = engine.connectionError, !dismissedError {
                    ToastBanner(
                        title: "No se pudo leer CloudWatch",
                        message: connectionError,
                        tint: Palette.amber,
                        actionTitle: "Reintentar",
                        action: { Task { await engine.refresh(forceValidation: true) } },
                        dismiss: { dismissedError = true }
                    )
                }

                if engine.liveTailError != nil, engine.isLive, !engine.isLiveTailing {
                    ToastBanner(
                        title: "Live Tail no disponible",
                        message: "La app sigue actualizando cada \(engine.configuration.pollIntervalSeconds) s. \(engine.liveTailError ?? "")",
                        tint: Palette.amber,
                        dismiss: nil
                    )
                }

                hero

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricTile(
                        title: "Última ejecución",
                        value: lastRunDate,
                        caption: engine.latestRun?.startedAt.formatted(date: .omitted, time: .shortened),
                        symbol: "calendar",
                        tint: Palette.blue
                    )
                    MetricTile(
                        title: "Duración",
                        value: engine.latestRun?.durationText ?? "—",
                        caption: engine.latestRun?.finished == true ? "Lambda completada" : "En curso",
                        symbol: "timer",
                        tint: Palette.violet
                    )
                    MetricTile(
                        title: "TXT descargados",
                        value: "\(engine.latestRun?.downloads ?? 0)",
                        caption: engine.latestRun?.periodText,
                        symbol: "doc.text.fill",
                        tint: Palette.green
                    )
                    MetricTile(
                        title: "Claves extraídas",
                        value: "\(engine.latestRun?.totalKeys ?? 0)",
                        caption: "Claves de acceso válidas",
                        symbol: "key.fill",
                        tint: Palette.amber
                    )
                }

                HStack(alignment: .top, spacing: 18) {
                    latestRunCard
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    systemCard
                        .frame(width: 330, alignment: .topLeading)
                }

                activityCard
            }
            .padding(26)
        }
        .sheet(isPresented: $showingInvoke) {
            InvokeRobotSheet()
                .environment(engine)
        }
        .onChange(of: engine.connectionError) { _, newValue in
            if newValue == nil { dismissedError = false }
        }
    }

    private var lastRunDate: String {
        guard let date = engine.latestRun?.startedAt else { return "—" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private var hero: some View {
        GlassCard(tint: engine.effectiveStatus.color, cornerRadius: 30, padding: 26) {
            HStack(spacing: 26) {
                StatusOrb(status: engine.effectiveStatus, size: 106)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Text(engine.effectiveStatus.title)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, .white.opacity(0.68)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: engine.effectiveStatus.symbolName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(engine.effectiveStatus.color)
                    }

                    Text(engine.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 500, alignment: .leading)

                    HStack(spacing: 6) {
                        Chip(text: "Perfil caliente", symbol: "flame.fill", tint: Palette.amber)
                        Chip(text: engine.configuration.functionName, symbol: "server.rack", tint: Palette.blue)
                        Chip(text: engine.configuration.region, symbol: "globe.americas.fill")
                        Chip(
                            text: engine.isLiveTailing ? "Live Tail" : "Sondeo",
                            symbol: engine.isLiveTailing ? "dot.radiowaves.left.and.right" : "arrow.clockwise",
                            tint: engine.isLiveTailing ? Palette.green : Palette.amber
                        )
                        if let run = engine.latestRun, run.finished {
                            Chip(text: "\(run.downloads) TXT · \(run.totalKeys) claves", symbol: "checkmark.seal")
                        }
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 10) {
                    Button {
                        showingInvoke = true
                    } label: {
                        Label("Relanzar robot", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.green)
                    .controlSize(.large)
                    .disabled(engine.isInvoking || engine.needsOnboarding)

                    Button {
                        Task { await engine.refresh(forceValidation: true) }
                    } label: {
                        Label("Actualizar estado", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .disabled(engine.isRefreshing)
                }
            }
        }
    }

    private var latestRunCard: some View {
        GlassCard(cornerRadius: 24, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(
                        title: "Última ejecución",
                        subtitle: engine.latestRun.map { $0.startedAt.formatted(date: .long, time: .standard) } ?? "Sin ejecuciones",
                        symbol: "clock.arrow.circlepath"
                    )
                    Spacer()
                    if let run = engine.latestRun {
                        StatusPill(status: run.status, compact: true)
                    }
                }

                if let run = engine.latestRun {
                    HStack(spacing: 22) {
                        MiniStat(title: "Períodos", value: run.periodText)
                        MiniStat(title: "Duración", value: run.durationText)
                        MiniStat(title: "Fallos", value: "\(run.failures)", tint: run.failures > 0 ? Palette.red : .white)
                        MiniStat(title: "Advertencias", value: "\(run.warningCount)", tint: run.warningCount > 0 ? Palette.amber : .white)
                    }

                    if !run.failureMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(run.failureMessages.prefix(2), id: \.self) { message in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Palette.red)
                                        .padding(.top, 2)
                                    Text(message)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Antes solo se decía "advertencia" sin explicar cuál era.
                    if !run.warningMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(run.warningMessages.prefix(3), id: \.self) { message in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Palette.amber)
                                        .padding(.top, 2)
                                    Text(message)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                            if run.warningMessages.count < run.warningCount {
                                Text("y \(run.warningCount - run.warningMessages.count) advertencia(s) más")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Button("Ver todas en el detalle") {
                                engine.selectedSection = .runs
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 9))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let lastRequest = engine.lastInvocationRequestID {
                        HStack(spacing: 8) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.blue)
                            Text("Último relanzamiento · \(lastRequest)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                    HStack(spacing: 8) {
                        Button {
                            engine.selectedSection = .logs
                        } label: {
                            Label("Ver registros", systemImage: "text.alignleft")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        Button {
                            engine.selectedSection = .runs
                        } label: {
                            Label("Historial", systemImage: "clock")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        Spacer()

                        if let requestID = engine.latestRun?.requestID {
                            Text(String(requestID.prefix(12)))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.28))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    EmptyStateView(
                        symbol: "moon.stars",
                        title: "Todavía no hay ejecuciones",
                        message: "Cuando el robot se ejecute en Lambda, el resumen aparecerá aquí automáticamente."
                    )
                }
            }
        }
    }

    private var systemCard: some View {
        GlassCard(cornerRadius: 24, padding: 20) {
            VStack(alignment: .leading, spacing: 13) {
                SectionTitle(title: "Conexión", subtitle: "Función e identidad de AWS", symbol: "network")

                if let function = engine.functionInfo {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(function.isActive ? Palette.green : Palette.amber)
                            .frame(width: 7, height: 7)
                        Text(function.healthText)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text("\(function.memorySize ?? 0) MB · \(function.timeout ?? 0) s")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: engine.isLiveTailing ? "dot.radiowaves.left.and.right" : "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(engine.isLiveTailing ? Palette.green : Palette.amber)
                    Text(engine.monitoringModeText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }

                VStack(spacing: 7) {
                    KeyValueRow(key: "Región", value: engine.configuration.region, monospaced: true)
                    KeyValueRow(key: "Función", value: engine.configuration.functionName, monospaced: true)
                    KeyValueRow(key: "Log group", value: engine.configuration.logGroupName, monospaced: true)
                    KeyValueRow(key: "Cuenta", value: engine.callerIdentity?.account ?? "—", monospaced: true)
                    KeyValueRow(key: "Identidad", value: engine.callerIdentity?.displayName ?? "Sin validar")
                    if let lastValidation = engine.lastValidationAt {
                        KeyValueRow(key: "Validada", value: lastValidation.formatted(date: .abbreviated, time: .shortened))
                    }
                    KeyValueRow(
                        key: "Claves robot",
                        value: engine.environment.isConfigured
                            ? "Portal + anti-captcha en el evento"
                            : "Las que trae la imagen"
                    )
                }

                Button {
                    engine.selectedSection = .settings
                } label: {
                    Label("Revalidar credenciales", systemImage: "checkmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private var activityCard: some View {
        GlassCard(cornerRadius: 24, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Actividad reciente", subtitle: "Últimas líneas recibidas de CloudWatch", symbol: "waveform.path.ecg")
                    Spacer()
                    Button {
                        engine.selectedSection = .logs
                    } label: {
                        Text("Ver todo")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if engine.logs.isEmpty {
                    EmptyStateView(
                        symbol: "text.alignleft",
                        title: "Sin registros todavía",
                        message: engine.logGroupMissing
                            ? "El log group aún no tiene eventos. Se llenará en la próxima ejecución."
                            : "Los registros aparecerán aquí en cuanto Lambda escriba en CloudWatch."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(engine.logs.suffix(7).reversed())) { entry in
                            LogRowView(entry: entry, compact: true)
                            if entry.id != engine.logs.suffix(7).first?.id {
                                Divider().overlay(.white.opacity(0.04))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MiniStat: View {
    let title: String
    let value: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
