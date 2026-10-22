import AppKit
import SwiftUI
import XCTest
@testable import SriRobotMonitor

/// Renderiza las vistas reales a PNG para revisarlas visualmente sin depender
/// de que haya una sesión gráfica desbloqueada. Se omite salvo que se pida con
/// `SRI_RENDER_SNAPSHOTS=1`.
@MainActor
final class SnapshotDumpTests: XCTestCase {
    private var engine = MonitorEngine()

    private var output: URL {
        // El host de pruebas corre dentro del sandbox de la app y solo puede
        // escribir en su propia carpeta temporal (`/var/folders/...`).
        FileManager.default.temporaryDirectory.appendingPathComponent("sri-snapshots", isDirectory: true)
    }

    override func setUpWithError() throws {
        // Las variables del proceso de pruebas no siempre llegan al runner de
        // xcodebuild; el archivo centinela hace la prueba explícita y repetible.
        let flag = ProcessInfo.processInfo.environment["SRI_RENDER_SNAPSHOTS_PLAIN"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/sri-render-snapshots.on")
        guard flag else {
            throw XCTSkip("Crea /tmp/sri-render-snapshots.on para generar capturas.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    func testDumpScreens() async throws {
        try dumpMenuBarIcons()
        // Onboarding y dashboards ya pintan su propio `AuroraBackground`.
        try dump("01-onboarding", OnboardingView(), width: 1_220, height: 800, withBackground: false)

        engine.needsOnboarding = false
        engine.isBootstrapped = true
        try dump("02-dashboard", ScreenShell(engine: engine, section: .dashboard), width: 1_220, height: 800, withBackground: false)
        try dump("03-logs", ScreenShell(engine: engine, section: .logs), width: 1_220, height: 800, withBackground: false)
        try dump("04-runs", ScreenShell(engine: engine, section: .runs), width: 1_220, height: 800, withBackground: false)
        try dump("05-settings", ScreenShell(engine: engine, section: .settings), width: 1_220, height: 900, withBackground: false)
        try dump("06-invoke", InvokeRobotSheet(), width: 620, height: 690, withBackground: false)
        try dump("07-revalidate", RevalidateCredentialsSheet(), width: 640, height: 720, withBackground: false)
    }

    /// Genera los iconos de la barra a tamaño real y ampliados, para poder
    /// juzgar la silueta sin depender de la barra de menús.
    private func dumpMenuBarIcons() throws {
        for status in RobotStatus.allCases {
            for (index, icon) in MenuBarIcon.frames(for: status).enumerated() {
                try writePNG(icon, name: "menubar-\(status.restLabel)-\(index)")
            }
        }
        try writePNG(
            try XCTUnwrap(MenuBarIcon.make(for: .running, size: 180)),
            name: "menubar-zoom-running"
        )
        // Sobre los dos fondos de la barra: claro (modo light) y oscuro.
        for (name, background) in [("light", Color.white), ("dark", Color(hex: 0x1E1E1E))] {
            for status in RobotStatus.allCases {
                // Se simula lo que hace macOS con la plantilla: silueta en el
                // color que contrasta, y el LED a color encima.
                let card = ZStack {
                    background
                    ZStack {
                        if name == "light" {
                            RobotGlyph(status: status, size: 180, monochromeSilhouette: true)
                        }
                        RobotGlyph(status: status, size: 180)
                    }
                }
                .frame(width: 220, height: 220)
                try dumpImage(card, name: "menubar-\(name)-\(status.restLabel)")
            }
        }
        // Tira que simula la barra de menús a tamaño real (18 pt), en claro y
        // oscuro, con los cinco estados. Es la prueba definitiva del icono.
        for (name, background) in [("light", Color(hex: 0xF2F2F2)), ("dark", Color(hex: 0x1E1E1E))] {
            let strip = HStack(spacing: 26) {
                ForEach(RobotStatus.allCases, id: \.self) { status in
                    ZStack {
                        if name == "light" {
                            RobotGlyph(status: status, size: 18, monochromeSilhouette: true)
                        }
                        RobotGlyph(status: status, size: 18)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 28)
            .background(background)
            try dumpImage(strip, name: "menubar-strip-\(name)")
        }
    }

    private func dumpImage<V: View>(_ view: V, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage else { return XCTFail("Sin imagen para \(name)") }
        try writePNG(image, name: name)
    }

    private func writePNG(_ image: NSImage, name: String) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("No se pudo exportar \(name)")
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("SNAPSHOT \(name): \(output.appendingPathComponent("\(name).png").path(percentEncoded: false))")
    }

    private func dump<V: View>(
        _ name: String,
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        withBackground: Bool = true
    ) throws {
        // Las hojas ya pintan `AuroraBackground`; duplicarlo las oscurecería.
        let content = ZStack {
            if withBackground { AuroraBackground() }
            view
                .environment(engine)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("No se pudo renderizar \(name)")
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("SNAPSHOT \(name): \(output.appendingPathComponent("\(name).png").path(percentEncoded: false))")
    }
}

/// Envuelve una sección con la barra lateral y la cabecera reales, para que la
/// captura se parezca a la ventana tal como la usa una persona.
private struct ScreenShell: View {
    let engine: MonitorEngine
    let section: AppSection

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .environment(engine)
                .frame(width: 252)
            VStack(spacing: 0) {
                ScreenHeader()
                Divider().overlay(.white.opacity(0.07))
                detail
            }
        }
        .onAppear { engine.selectedSection = section }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .dashboard: DashboardView()
        case .runs: RunsView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
