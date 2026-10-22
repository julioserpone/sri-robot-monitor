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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: RobotStatus
    /// Los dos fotogramas de la animación (`running`). Se dibujan una vez
    /// porque `ImageRenderer` es caro como para repetirlo en cada tick.
    @State private var frames: [NSImage] = []
    @State private var frameIndex = 0

    private var isRunning: Bool { status == .running }

    var body: some View {
        Group {
            if frames.indices.contains(frameIndex) {
                Image(nsImage: frames[frameIndex])
                    .accessibilityLabel(accessibilityText)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .accessibilityLabel(accessibilityText)
            }
        }
        .task(id: status) {
            frames = MenuBarIcon.frames(for: status)
            frameIndex = 0
        }
        .task(id: isRunning) {
            // Mientras el robot trabaja, la antena emite. Solo cambia la imagen
            // ya dibujada, así que no cuesta más que cambiar un píxel.
            guard isRunning, !reduceMotion, frames.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.2)) {
                    frameIndex = (frameIndex + 1) % frames.count
                }
            }
        }
    }

    private var accessibilityText: String {
        isRunning ? "SRI Robot: ejecutando" : "SRI Robot: \(status.title)"
    }
}

/// Icono de la barra de menús.
///
/// Dos cosas que `MenuBarExtra` impone y obligan a dibujarlo a mano:
///
/// 1. Trata sus `Image` como plantilla: ignora el color y lo pinta con el del
///    sistema. Por eso un LED de color se veía como un punto gris.
/// 2. No admite animaciones: el estado solo cambia cuando cambia la etiqueta.
///
/// El icono es una antena de robot (la marca de la app) con el LED de estado
/// en la base. Se dibuja con `NSImage.isTemplate = false` para conservar el
/// color, y en dos fotogramas para que la antena emita mientras el robot
/// trabaja.
@MainActor
enum MenuBarIcon {
    static let size: CGFloat = 18

    /// Fotogramas del estado. Uno para los estados quietos, dos para el ejecutante.
    static func frames(for status: RobotStatus) -> [NSImage] {
        let indices = status == .running ? [0, 1] : [0]
        return indices.compactMap { make(for: status, phase: $0) }
    }

    static func make(for status: RobotStatus, phase: Int = 0, size: CGFloat = size) -> NSImage? {
        let emphasis = phase == 0 ? 1.0 : 0.55
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        // La imagen se entrega como plantilla: macOS la pinta con el color que
        // contrasta sobre la barra clara u oscura. Si se dibujara en blanco
        // fijo, en modo claro desaparecería (el bug reportado).
        if let silhouette = render(monochrome: true, emphasis: emphasis, size: size) {
            silhouette.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        } else {
            return nil
        }

        // El LED va a color encima: una plantilla no admite color.
        if let led = renderLED(status: status, size: size) {
            led.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        }

        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func render(monochrome: Bool, emphasis: Double, size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(
            content: RobotGlyph(
                status: .healthy,
                emphasis: emphasis,
                size: size,
                monochromeSilhouette: monochrome
            )
            .frame(width: size, height: size)
        )
        renderer.scale = 2
        return renderer.nsImage
    }

    private static func renderLED(status: RobotStatus, size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(
            content: Circle()
                .fill(status.color)
                .frame(width: size * 0.46, height: size * 0.46)
                .frame(width: size, height: size, alignment: .center)
                .offset(y: -size * 0.05)
        )
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// Antena de robot con el LED de estado.
///
/// La silueta es la de la marca de la app: antena con ondas de emisión a los
/// lados y el LED de estado como cabeza. Se compone en dos capas cuando se usa
/// en la barra de menús: la silueta en negro como plantilla (macOS la pinta del
/// color que contrasta) y el LED a color encima.
struct RobotGlyph: View {
    let status: RobotStatus
    /// 1 = ondas visibles; <1 = ondas atenuadas para el fotograma animado.
    var emphasis: Double = 1
    var size: CGFloat = 18
    /// `true` deja solo lo que debe heredar el color del sistema (plantilla).
    var monochromeSilhouette = false

    var body: some View {
        // A 18 px solo caben tres signos: cabeza, mástil y ondas. Los símbolos
        // `wave.2.*` no existen en SF Symbols (solo `wave.3.*`), y ese error
        // dejaba el icono como un punto sin ondas.
        let mastInk = monochromeSilhouette ? Color.black : Color.white
        let waveInk = monochromeSilhouette ? Color.black : Color.white
        let cap = size * 0.46

        ZStack {
            // Silueta: ondas y mástil. Va en la capa de plantilla (para que
            // macOS la pinte del color que contraste) y también en la capa a
            // color, porque la imagen final no es plantilla.
            RobotStructure(ink: waveInk, emphasis: emphasis, size: size)

            if monochromeSilhouette {
                Circle()
                    .strokeBorder(waveInk, lineWidth: max(1.5, size * 0.14))
                    .frame(width: cap, height: cap)
                    .offset(y: -size * 0.05)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: cap, height: cap)
                    .offset(y: -size * 0.05)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Ondas y mástil del robot. Separado para poder dibujarlo en las dos capas
/// del icono sin duplicar geometría.
struct RobotStructure: View {
    let ink: Color
    var emphasis: Double = 1
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Image(systemName: "wave.3.right")
                .font(.system(size: size * 0.62, weight: .black))
                .foregroundStyle(ink)
                .offset(x: size * 0.36)
                .opacity(emphasis)
            Image(systemName: "wave.3.left")
                .font(.system(size: size * 0.62, weight: .black))
                .foregroundStyle(ink)
                .offset(x: -size * 0.36)
                .opacity(emphasis)
            Capsule()
                .fill(ink)
                .frame(width: max(1.6, size * 0.12), height: size * 0.26)
                .offset(y: size * 0.30)
        }
        .frame(width: size, height: size)
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

extension RobotStatus {
    /// Nombre estable para los archivos de depuración del icono.
    var restLabel: String { rawValue }
}
