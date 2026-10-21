import SwiftUI

struct InvokeRobotSheet: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPeriods: Set<String> = [Periodo.previousClosedMonth().key]
    @State private var useFunctionTypes = true
    @State private var selectedTypes: Set<String> = Set(SRIComprobanteType.all.map(\.code))
    @State private var force = false
    @State private var waitForResult = false
    @State private var errorMessage: String?
    @State private var submitting = false

    /// El modo `tail` envía las claves del robot en el evento: si no están
    /// guardadas, la app avisa antes de esperar 60 s en balde.
    private var environmentSummary: String {
        let env = engine.environment
        switch (env.portalPassword.isEmpty, env.anticaptchaKey.isEmpty) {
        case (false, false): return "Clave del portal y anti-captcha configuradas"
        case (false, true): return "Solo clave del portal; falta anti-captcha"
        case (true, false): return "Solo anti-captcha; falta clave del portal"
        case (true, true): return "Sin claves: se usan las de la imagen"
        }
    }

    private var periods: [Periodo] {
        Periodo.recent(count: 12)
    }

    private var resolvedPeriods: [Periodo] {
        selectedPeriods.compactMap(Periodo.fromKey).sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    warmProfileCard
                    periodsCard
                    typesCard
                    optionsCard

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.red)
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.78))
                            Spacer()
                        }
                        .padding(12)
                        .background(Palette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(22)
            }

            Divider().overlay(.white.opacity(0.07))
            footer
        }
        .frame(width: 620, height: 690)
        .background(AuroraBackground())
        .interactiveDismissDisabled(submitting)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.green.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Relanzar robot")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Invoca la imagen publicada con el perfil de Chrome caliente.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(submitting)
        }
        .padding(22)
    }

    private var warmProfileCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flame.fill")
                .font(.system(size: 16))
                .foregroundStyle(Palette.amber)
            VStack(alignment: .leading, spacing: 4) {
                Text("Perfil caliente")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("La función \(engine.configuration.functionName) ya contiene el perfil que resolvió el reCAPTCHA. La app solo dispara una nueva invocación asíncrona; no vuelve a construir ni a subir la imagen.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.amber.opacity(0.16), lineWidth: 1)
        }
    }

    private var periodsCard: some View {
        GlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Períodos", subtitle: "Selecciona uno o varios meses cerrados", symbol: "calendar")
                    Spacer()
                    Button("Mes anterior") {
                        selectedPeriods = [Periodo.previousClosedMonth().key]
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                    ForEach(periods) { period in
                        let isOn = selectedPeriods.contains(period.key)
                        Button {
                            if isOn {
                                selectedPeriods.remove(period.key)
                            } else {
                                selectedPeriods.insert(period.key)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(period.shortLabel)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(isOn ? Palette.green : .white.opacity(0.54))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                isOn ? Palette.green.opacity(0.09) : .white.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isOn ? Palette.green.opacity(0.26) : .white.opacity(0.06),
                                        lineWidth: 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var typesCard: some View {
        GlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $useFunctionTypes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usar los tipos configurados en Lambda")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Si está apagado, el evento enviará los tipos marcados abajo.")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if !useFunctionTypes {
                    Divider().overlay(.white.opacity(0.05))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(SRIComprobanteType.all) { type in
                            let isOn = selectedTypes.contains(type.code)
                            Button {
                                if isOn {
                                    selectedTypes.remove(type.code)
                                } else {
                                    selectedTypes.insert(type.code)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 11))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(type.code)
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Palette.textSecondary)
                                        Text(type.label)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(isOn ? Palette.blue : .white.opacity(0.54))
                                .padding(9)
                                .background(
                                    isOn ? Palette.blue.opacity(0.08) : .white.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            isOn ? Palette.blue.opacity(0.24) : .white.opacity(0.06),
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var optionsCard: some View {
        GlassCard(cornerRadius: 20, padding: 16) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: $force) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Forzar nueva descarga")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Ignora la idempotencia de S3 y vuelve a consultar el portal.")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer()
                }

                Divider().overlay(.white.opacity(0.05))

                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: $waitForResult) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Esperar el resultado")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Modo tail: mantiene la conexión hasta el RESUMEN y envía las claves guardadas en el evento. Si está apagado, la app recibe el RequestId y sigue por Live Tail.")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: engine.environment.isConfigured ? "key.fill" : "key.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(engine.environment.isConfigured ? Palette.green : Palette.textSecondary)
                    Text(environmentSummary)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("Configurar claves") {
                        dismiss()
                        engine.selectedSection = .settings
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 9))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedPeriods.isEmpty ? "Sin períodos seleccionados" : resolvedPeriods.map(\.key).joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(resolvedPeriods.isEmpty ? Palette.amber : .white.opacity(0.72))
                Text(useFunctionTypes ? "Tipos: configuración de Lambda" : "Tipos: \(selectedTypes.sorted().joined(separator: ", "))")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.textSecondary)
                Text(waitForResult ? "Se esperará el RESUMEN de la ejecución" : "Invocación asíncrona · progreso por Live Tail")
                    .font(.system(size: 9))
                    .foregroundStyle(waitForResult ? Palette.blue : Palette.textSecondary)
            }
            Spacer()
            Button("Cancelar") {
                dismiss()
            }
            .buttonStyle(.glass)
            .disabled(submitting)

            Button {
                submit()
            } label: {
                HStack(spacing: 7) {
                    if submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(submitting
                        ? (waitForResult ? "Esperando resultado…" : "Invocando…")
                        : "Ejecutar ahora")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.green)
            .controlSize(.large)
            .disabled(submitting || resolvedPeriods.isEmpty)
        }
        .padding(18)
    }

    private func submit() {
        errorMessage = nil
        submitting = true
        let periods = resolvedPeriods
        let types = useFunctionTypes ? [] : Array(selectedTypes).sorted()
        let wait = waitForResult
        Task {
            do {
                try await engine.invoke(periods: periods, types: types, force: force, waitForResult: wait)
                submitting = false
                dismiss()
            } catch {
                submitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SRIComprobanteType: Identifiable, Hashable {
    let code: String
    let label: String

    var id: String { code }

    static let all: [SRIComprobanteType] = [
        .init(code: "01", label: "Factura"),
        .init(code: "03", label: "Liquidación de compra"),
        .init(code: "04", label: "Nota de crédito"),
        .init(code: "05", label: "Nota de débito"),
        .init(code: "07", label: "Comprobante de retención")
    ]
}
