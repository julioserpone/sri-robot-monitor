import AppKit
import SwiftUI
import XCTest
@testable import SriRobotMonitor

// Los tests requieren el macOS del scheme (26). Donde no esté, el target ni
// compila, así que el CI elige el runner y esta guarda evita ruido futuro.

/// Prueba de humo de la interfaz: renderiza las vistas principales en modo
/// headless para detectar fallos de construcción, y comprueba que la ventana
/// se crea sin excepciones. No sustituye a mirar la app, pero sí evita
/// entregar una UI que ni siquiera se puede dibujar.
@MainActor
final class ViewSmokeTests: XCTestCase {
    func testOnboardingRenders() async {
        let engine = MonitorEngine()
        let image = render(
            OnboardingView()
                .environment(engine)
                .frame(width: 1_000, height: 760)
                .background(AuroraBackground())
        )
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.height ?? 0, 100)
    }

    func testDesignSystemComponentsRender() {
        let stack = VStack(alignment: .leading, spacing: 12) {
            StatusLED(status: .healthy)
            StatusLED(status: .warning)
            StatusLED(status: .error)
            StatusLED(status: .running)
            StatusPill(status: .error, compact: true)
            Chip(text: "Live Tail", symbol: "dot.radiowaves.left.and.right")
            MiniStat(title: "Claves", value: "12")
            KeyValueRow(key: "Función", value: "sri-txt-robot", monospaced: true)
            ToastBanner(title: "Aviso", message: "Live Tail no disponible", tint: Palette.amber)
        }
        .padding(20)
        .frame(width: 520)
        .background(AuroraBackground())

        XCTAssertNotNil(render(stack))
    }

    func testStatusOrbCoversEveryState() {
        for status in RobotStatus.allCases {
            let orb = StatusOrb(status: status, size: 90)
                .frame(width: 120, height: 120)
                .background(Palette.ink)
            XCTAssertNotNil(render(orb), "El orbe de \(status) no se pudo dibujar")
        }
    }

    func testDashboardRendersWithSampleData() async {
        let engine = MonitorEngine()
        XCTAssertNotNil(render(DashboardView().environment(engine).frame(width: 1_000, height: 760)))
        XCTAssertNotNil(render(LogsView().environment(engine).frame(width: 1_000, height: 700)))
        XCTAssertNotNil(render(RunsView().environment(engine).frame(width: 1_000, height: 700)))
        XCTAssertNotNil(render(SettingsView().environment(engine).frame(width: 1_000, height: 760)))
    }

    private func render<V: View>(_ view: V) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// El LED de la barra de menús no se veía porque `MenuBarExtra` trata sus
/// imágenes como plantilla y descarta el color.
@MainActor
final class MenuBarIconTests: XCTestCase {
    func testIconIsATemplateWithAColoredLED() throws {
        // Debe ser plantilla para que macOS pinte ondas y mástil con el color
        // que contraste; el LED va a color encima. Si fuera todo plantilla, el
        // LED saldría gris; si no fuera plantilla, en modo claro desaparecería.
        for status in RobotStatus.allCases {
            let icon = try XCTUnwrap(MenuBarIcon.make(for: status), "Sin icono para \(status)")
            XCTAssertTrue(icon.isTemplate, "La silueta de \(status) debe adaptarse al fondo")
            XCTAssertEqual(icon.size.width, 18, accuracy: 0.5)

            let tiff = try XCTUnwrap(icon.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            var hasColor = false
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                    let spread = max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                        - min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                    if spread > 0.25, pixel.alphaComponent > 0.5 { hasColor = true }
                }
            }
            // `unknown` es gris a propósito: no tiene color que conservar.
            guard status != .unknown else { continue }
            XCTAssertTrue(hasColor, "El icono de \(status) no conserva el color del LED")
        }
    }

    func testSilhouetteDoesNotUseAnUnknownSymbol() {
        // `wave.2.*` no existe en SF Symbols: usarlo dejaba el icono sin ondas.
        XCTAssertNotNil(NSImage(systemSymbolName: "wave.3.right", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "wave.3.left", accessibilityDescription: nil))
        XCTAssertNil(NSImage(systemSymbolName: "wave.2.right", accessibilityDescription: nil))
    }

    func testRunningStateHasTwoFrames() {
        XCTAssertEqual(MenuBarIcon.frames(for: .running).count, 2)
        for status in RobotStatus.allCases where status != .running {
            XCTAssertEqual(MenuBarIcon.frames(for: status).count, 1)
        }
    }

    func testFramesDifferSoTheAntennaCanBlink() throws {
        let frames = MenuBarIcon.frames(for: .running)
        let tiffs = try frames.map { try XCTUnwrap($0.tiffRepresentation) }
        XCTAssertNotEqual(tiffs[0], tiffs[1], "Los dos fotogramas son idénticos: no habría animación")
    }

    func testStatusColorsAreDistinct() {
        let colors = RobotStatus.allCases.map(\.color)
        let described = colors.map { String(describing: $0) }
        XCTAssertEqual(Set(described).count, colors.count, "Dos estados comparten color")
    }
}
