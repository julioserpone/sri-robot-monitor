import SwiftUI

@main
struct SriRobotMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = MonitorEngine()

    var body: some Scene {
        WindowGroup("SRI Robot Monitor", id: "main") {
            RootView()
                .environment(engine)
                .frame(minWidth: 1_020, minHeight: 680)
                .task { await engine.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1_220, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Actualizar estado") {
                    Task { await engine.refresh(forceValidation: true) }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Ir a Registros") {
                    engine.selectedSection = .logs
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Ir a Ejecuciones") {
                    engine.selectedSection = .runs
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(engine)
        } label: {
            MenuBarLabel(status: engine.effectiveStatus)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let status: RobotStatus

    var body: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(status.color)
            .accessibilityLabel("SRI Robot: \(status.title)")
    }
}

struct RootView: View {
    @Environment(MonitorEngine.self) private var engine

    var body: some View {
        ZStack {
            AuroraBackground()

            if !engine.isBootstrapped {
                LaunchView()
            } else if engine.needsOnboarding {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.green)
    }
}

struct LaunchView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            AppMark(size: 82)
                .scaleEffect(pulse ? 1.04 : 0.98)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulse)
            VStack(spacing: 6) {
                Text("SRI Robot Monitor")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Abriendo el canal con AWS…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulse = true }
    }
}

struct AppMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x1D2A38), Color(hex: 0x0C1119)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Palette.green, Palette.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Palette.green)
                .frame(width: size * 0.11, height: size * 0.11)
                .shadow(color: Palette.green, radius: size * 0.08)
                .offset(x: size * 0.27, y: -size * 0.27)
        }
        .frame(width: size, height: size)
    }
}
