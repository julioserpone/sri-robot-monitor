import SwiftUI

enum Palette {
    static let green = Color(hex: 0x3DE58C)
    static let amber = Color(hex: 0xFFB340)
    static let red = Color(hex: 0xFF5D68)
    static let blue = Color(hex: 0x66A8FF)
    static let violet = Color(hex: 0x9B8CFF)
    static let ink = Color(hex: 0x070A11)
    static let panel = Color(hex: 0x111722)
    static let textSecondary = Color.white.opacity(0.62)
    static let stroke = Color.white.opacity(0.10)
}

extension RobotStatus {
    var color: Color {
        switch self {
        case .unknown: Color.white.opacity(0.38)
        case .running: Palette.blue
        case .healthy: Palette.green
        case .warning: Palette.amber
        case .error: Palette.red
        }
    }

    var softColor: Color {
        color.opacity(0.16)
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .system: Color.white.opacity(0.42)
        case .debug: Palette.violet
        case .info: Palette.blue
        case .warning: Palette.amber
        case .error: Palette.red
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// Fondo tipo "aurora" que da contexto al cristal líquido.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x080B12), Color(hex: 0x0A111A), Color(hex: 0x06070B)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Palette.green.opacity(0.16))
                .frame(width: 560, height: 560)
                .blur(radius: 110)
                .offset(x: drift ? -230 : -180, y: drift ? -260 : -220)

            Circle()
                .fill(Palette.violet.opacity(0.18))
                .frame(width: 620, height: 620)
                .blur(radius: 130)
                .offset(x: drift ? 310 : 260, y: drift ? -170 : -120)

            Circle()
                .fill(Palette.blue.opacity(0.10))
                .frame(width: 700, height: 700)
                .blur(radius: 150)
                .offset(x: drift ? -120 : -60, y: drift ? 380 : 330)

            Rectangle()
                .fill(.black.opacity(0.18))
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

/// Tarjeta de cristal líquido reutilizable.
struct GlassCard<Content: View>: View {
    var tint: Color?
    var cornerRadius: CGFloat = 26
    var padding: CGFloat = 22
    @ViewBuilder var content: () -> Content

    init(
        tint: Color? = nil,
        cornerRadius: CGFloat = 26,
        padding: CGFloat = 22,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass: Glass = if let tint {
            .regular.tint(tint.opacity(0.12)).interactive()
        } else {
            .regular
        }

        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(glass, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
            }
    }
}

struct SectionTitle: View {
    var title: String
    var subtitle: String?
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// El LED de estado. Verde = operativo, naranja = advertencias, rojo = error,
/// gris = sin datos, azul (pulso) = ejecutando.
///
/// No transmite solo color: lleva símbolo, texto y `accessibilityLabel`, y
/// vibra cuando reduce-motion está activo.
struct StatusLED: View {
    let status: RobotStatus
    var size: CGFloat = 14
    var showLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: size * 0.5) {
            ZStack {
                Circle()
                    .fill(status.color.opacity(0.22))
                    .frame(width: size * 2, height: size * 2)
                    .scaleEffect(pulse ? 1.15 : 1)
                    .opacity(pulse ? 0.2 : 0.75)
                Circle()
                    .fill(status.color)
                    .frame(width: size, height: size)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.6)
                    }
                    .shadow(color: status.color.opacity(0.8), radius: size * 0.35)
            }
            .frame(width: size * 2, height: size * 2)
            .onAppear { updatePulse() }
            .onChange(of: status) { _, _ in updatePulse() }

            if showLabel {
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.shortTitle)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(status.color)
                    Text(status.ledCaption)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estado del robot: \(status.title). \(status.ledCaption)")
    }

    private func updatePulse() {
        if status == .running, !reduceMotion {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}

struct StatusPill: View {
    let status: RobotStatus
    var compact = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.color)
                .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                .shadow(color: status.color.opacity(0.75), radius: 5)
            Text(compact ? status.shortTitle : status.title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 4 : 6)
        .background(status.softColor, in: .capsule)
        .overlay {
            Capsule().strokeBorder(status.color.opacity(0.25), lineWidth: 2)
        }
        .foregroundStyle(status.color)
        .accessibilityLabel("Estado: \(status.title)")
    }
}

struct LevelBadge: View {
    let level: LogLevel

    var body: some View {
        Text(level.title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(level.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(level.color.opacity(0.14), in: .capsule)
            .overlay {
                Capsule().strokeBorder(level.color.opacity(0.22), lineWidth: 1)
            }
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .white.opacity(0.55)

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.05), in: .capsule)
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var caption: String?
    var symbol: String
    var tint: Color = Palette.blue

    var body: some View {
        GlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    if let caption {
                        Text(caption)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct StatusOrb: View {
    let status: RobotStatus
    var size: CGFloat = 92
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [status.color.opacity(0.34), status.color.opacity(0.02)],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.55
                    )
                )
                .frame(width: size * 1.2, height: size * 1.2)
                .blur(radius: 8)

            Circle()
                .strokeBorder(status.color.opacity(0.22), lineWidth: 1)
                .frame(width: size, height: size)

            Circle()
                .strokeBorder(status.color.opacity(0.35), lineWidth: 1.5)
                .frame(width: size * 0.78, height: size * 0.78)
                .scaleEffect(status == .running && pulse ? 1.1 : 1)
                .opacity(status == .running && pulse ? 0.25 : 0.8)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [status.color.opacity(0.98), status.color.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.46, height: size * 0.46)
                .overlay {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.58), .white.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                        .frame(width: size * 0.22, height: size * 0.22)
                        .offset(x: -size * 0.07, y: -size * 0.08)
                }
                .shadow(color: status.color.opacity(0.85), radius: size * 0.16)
                .scaleEffect(status == .running && pulse ? 1.05 : 1)

            Image(systemName: status.symbolName)
                .font(.system(size: size * 0.18, weight: .bold))
                .foregroundStyle(.black.opacity(0.62))
                .offset(y: size * 0.24)
        }
        .frame(width: size * 1.25, height: size * 1.25)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: status) { _, _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        if status == .running {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .rounded))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

struct ToastBanner: View {
    let title: String
    let message: String
    var tint: Color
    var actionTitle: String?
    var action: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cerrar aviso")
            }
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }
}
