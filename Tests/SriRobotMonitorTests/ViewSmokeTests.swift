import XCTest
import SwiftUI
@testable import SriRobotMonitor

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
