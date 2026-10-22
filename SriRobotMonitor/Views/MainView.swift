import SwiftUI

struct MainView: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 232, ideal: 252, max: 286)
        } detail: {
            VStack(spacing: 0) {
                ScreenHeader()
                Divider().overlay(.white.opacity(0.07))
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.clear)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        switch engine.selectedSection {
        case .dashboard:
            DashboardView()
        case .runs:
            RunsView()
        case .files:
            FilesView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }
}

struct SidebarView: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppMark(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SRI Robot")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Monitor de ejecuciones")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    SidebarButton(
                        section: section,
                        isSelected: engine.selectedSection == section,
                        badge: badge(for: section)
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            engine.selectedSection = section
                        }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusLED(status: engine.effectiveStatus, size: 9)
                    Spacer(minLength: 0)
                }

                if let identity = engine.callerIdentity {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CUENTA AWS")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(Palette.textSecondary)
                        Text(identity.account)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(identity.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Sin conexión validada")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                }

                Button {
                    engine.selectedSection = .settings
                } label: {
                    Label("Gestionar conexión", systemImage: "key.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(13)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
            .padding(12)

            HStack(spacing: 5) {
                Circle()
                    .fill(engine.isLive ? (engine.isLiveTailing ? Palette.green : Palette.amber) : Palette.amber)
                    .frame(width: 5, height: 5)
                Text(engine.monitoringModeText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(Self.versionText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.white.opacity(0.018))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    static var versionText: String {
        "v\(AppVersion.short)"
    }

    private func badge(for section: AppSection) -> String? {
        switch section {
        case .files:
            let count = engine.bucketTree.flatMap(\.files).count
            return count == 0 ? nil : "\(min(count, 99))"
        case .runs:
            return engine.runs.isEmpty ? nil : "\(min(engine.runs.count, 99))"
        case .logs:
            return engine.logs.isEmpty ? nil : "\(min(engine.logs.count, 99))"
        default:
            return nil
        }
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Palette.green : .white.opacity(0.5))
                Text(section.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.07), in: .capsule)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.09))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ScreenHeader: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.selectedSection.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(engine.selectedSection.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 10)

            if let lastSync = engine.lastSync {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text("Actualizado \(lastSync.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.04), in: .capsule)
            }

            StatusLED(status: engine.effectiveStatus, size: 8)

            Button {
                Task { await engine.refresh(forceValidation: true) }
            } label: {
                Image(systemName: engine.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(engine.isRefreshing ? 360 : 0))
                    .animation(
                        engine.isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: engine.isRefreshing
                    )
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .help("Actualizar ahora (⌘R)")
            .disabled(engine.isRefreshing)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(.clear)
    }
}

struct MenuBarView: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    @State private var showingInvoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SRI Robot")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(engine.effectiveStatus.title)
                        .font(.system(size: 10))
                        .foregroundStyle(engine.effectiveStatus.color)
                }
                Spacer()
                Circle()
                    .fill(engine.effectiveStatus.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: engine.effectiveStatus.color, radius: 5)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)

            if let run = engine.latestRun {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Última ejecución")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                    Text(run.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Label(run.durationText, systemImage: "timer")
                        Label("\(run.downloads) TXT", systemImage: "doc.text")
                        Label("\(run.totalKeys) claves", systemImage: "key")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.textSecondary)
                }
                .padding(10)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Abrir panel", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Button {
                    showingInvoke = true
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 24)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.green)
                .help("Relanzar robot")
            }

            if let error = engine.connectionError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.amber)
                    .lineLimit(3)
            } else if let run = engine.latestRun, run.status == .error {
                Text(run.failureMessages.first ?? "La última ejecución falló.")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.red)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(width: 286)
        .sheet(isPresented: $showingInvoke) {
            InvokeRobotSheet()
                .environment(engine)
        }
    }
}
