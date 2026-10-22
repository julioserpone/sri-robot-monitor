import SwiftUI

struct OnboardingView: View {
    @Environment(MonitorEngine.self) private var engine

    @State private var step = 0
    @State private var draft = AWSSetupDraft()
    @State private var identity: CallerIdentity?
    @State private var function: LambdaFunctionInfo?
    @State private var testing = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var showSecrets = false
    @State private var notificationsEnabled = true

    private let totalSteps = 3

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 20) {
                        if step == 0 {
                            welcomeCard
                        } else {
                            formCard
                        }
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            AppMark(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("SRI Robot Monitor")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(step == 0 ? "Primera instalación" : "Paso \(step) de \(totalSteps)")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if step > 0 {
                HStack(spacing: 6) {
                    ForEach(1...totalSteps, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? Palette.green : .white.opacity(0.10))
                            .frame(width: index == step ? 22 : 7, height: 5)
                            .animation(.snappy, value: step)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var welcomeCard: some View {
        GlassCard(tint: Palette.green, cornerRadius: 30, padding: 34) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 22) {
                    ZStack {
                        Circle()
                            .fill(Palette.green.opacity(0.10))
                            .frame(width: 100, height: 100)
                        Circle()
                            .strokeBorder(Palette.green.opacity(0.24), lineWidth: 1)
                            .frame(width: 78, height: 78)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(Palette.green)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tu robot del SRI,\nen tiempo real.")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineSpacing(-2)
                        Text("Una app nativa de macOS para supervisar la imagen de sri-txt-robot en AWS Lambda. Sin consola, sin CLI y sin adivinar qué pasó.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    feature(
                        symbol: "circle.fill",
                        tint: Palette.green,
                        title: "LED de estado",
                        detail: "Mira el color y sabrás en qué etapa está el robot: si está buscando facturas, si terminó bien o si algo falló."
                    )
                    feature(
                        symbol: "text.alignleft",
                        tint: Palette.blue,
                        title: "Logs en vivo",
                        detail: "Las líneas de CloudWatch llegan mientras el robot trabaja, sin esperar a que termine."
                    )
                    feature(
                        symbol: "play.circle.fill",
                        tint: Palette.violet,
                        title: "Relanzar",
                        detail: "Vuelve a ejecutar el perfil caliente desde la app, sin abrir la consola de AWS."
                    )
                }

                Divider().overlay(.white.opacity(0.07))

                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 9))
                        Text("Credenciales en el Llavero")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Palette.textSecondary)

                    Spacer()

                    SetupButton(title: "Configurar AWS", symbol: "arrow.right", action: {
                        withAnimation(.snappy(duration: 0.25)) { step = 1 }
                    })
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private var formCard: some View {
        GlassCard(tint: step == 2 ? Palette.blue : Palette.green, cornerRadius: 28, padding: 28) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step == 1 ? "Credenciales de AWS" : step == 2 ? "Función del robot" : "Casi listo")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(step == 1
                        ? "Usa un usuario IAM con permisos mínimos. La app valida la identidad con STS."
                        : step == 2
                            ? "Indica la función publicada que contiene el perfil de Chrome caliente."
                            : "Revisa la conexión y decide si quieres recibir alertas.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }

                if step == 1 {
                    credentialsStep
                } else if step == 2 {
                    functionStep
                } else {
                    summaryStep
                }

                if let errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.red)
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.78))
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(12)
                    .background(Palette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Divider().overlay(.white.opacity(0.06))

                HStack(spacing: 10) {
                    SetupButton(title: "Atrás", symbol: "chevron.left", role: .secondary, minWidth: 96) {
                        withAnimation(.snappy(duration: 0.25)) { step = max(0, step - 1) }
                        errorMessage = nil
                    }
                    .disabled(saving)

                    Spacer()

                    if step == 1 {
                        SetupButton(
                            title: testing ? "Validando…" : "Probar credenciales",
                            symbol: "checkmark.shield",
                            role: .secondary,
                            loading: testing,
                            minWidth: 160,
                            action: testCredentials
                        )
                        .disabled(testing || !draft.hasCredentials)

                        SetupButton(title: "Continuar", symbol: "arrow.right") {
                            withAnimation(.snappy(duration: 0.25)) { step = 2 }
                            errorMessage = nil
                        }
                        .disabled(identity == nil)
                    } else if step == 2 {
                        SetupButton(
                            title: testing ? "Comprobando…" : "Comprobar función",
                            symbol: "server.rack",
                            role: .secondary,
                            loading: testing,
                            minWidth: 160,
                            action: testFunction
                        )
                        .disabled(testing || !draft.hasCredentials || draft.functionName.isEmpty)

                        SetupButton(title: "Continuar", symbol: "arrow.right") {
                            withAnimation(.snappy(duration: 0.25)) { step = 3 }
                            errorMessage = nil
                        }
                        .disabled(function == nil)
                    } else {
                        SetupButton(
                            title: saving ? "Guardando…" : "Empezar a supervisar",
                            symbol: "play.fill",
                            loading: saving,
                            minWidth: 190,
                            action: save
                        )
                        .disabled(saving)
                    }
                }
            }
        }
    }

    private var credentialsStep: some View {
        VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                LabeledField(title: "Región", symbol: "globe.americas.fill") {
                    SetupTextField("us-east-1", text: $draft.region)
                }
                .onChange(of: draft.region) { _, _ in invalidateConnection() }

                LabeledField(title: "Access Key ID", symbol: "person.badge.key") {
                    SetupTextField("AKIA…", text: $draft.accessKeyID)
                }
                .onChange(of: draft.accessKeyID) { _, _ in invalidateConnection() }
            }

            // Un solo campo por secreto, oculto o visible: intercambiar
            // `TextField` y `SecureField` destruye la vista y el foco salta.
            LabeledField(title: "Secret Access Key", symbol: "lock.fill") {
                SecretTextField("Secret Access Key", text: $draft.secretAccessKey, revealed: showSecrets)
            }
            .onChange(of: draft.secretAccessKey) { _, _ in invalidateConnection() }

            LabeledField(title: "Session token (opcional)", symbol: "clock.badge.checkmark") {
                SecretTextField("Solo credenciales temporales", text: $draft.sessionToken, revealed: showSecrets)
            }
            .onChange(of: draft.sessionToken) { _, _ in invalidateConnection() }

            HStack {
                Toggle(isOn: $showSecrets) {
                    Text("Mostrar secretos")
                        .font(.system(size: 9))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .animation(nil, value: showSecrets)

                Spacer()

                if let identity {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Palette.green)
                        Text("Cuenta \(identity.account) · \(identity.displayName)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Palette.green)
                    }
                }
            }

            Text("Permiso mínimo recomendado: sts:GetCallerIdentity, lambda:GetFunctionConfiguration, lambda:InvokeFunction, logs:FilterLogEvents, logs:StartLiveTail y s3:GetObject.")
                .font(.system(size: 8.5))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// Cambiar cualquier dato invalida la prueba anterior, pero solo eso:
    /// no reescribe el borrador ni reinicia los otros pasos.
    private func invalidateConnection() {
        identity = nil
        errorMessage = nil
    }

    private var functionStep: some View {
        VStack(spacing: 11) {
            if let identity {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.green)
                    Text("Credenciales válidas · cuenta \(identity.account)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Palette.green)
                    Spacer()
                }
            }

            HStack(alignment: .top, spacing: 11) {
                LabeledField(title: "Función de Lambda", symbol: "server.rack") {
                    SetupTextField("sri-txt-robot", text: $draft.functionName)
                }
                .onChange(of: draft.functionName) { oldValue, newValue in
                    if draft.logGroupName == RobotConfiguration.defaultLogGroup(for: oldValue)
                        || draft.logGroupName.isEmpty {
                        draft.logGroupName = RobotConfiguration.defaultLogGroup(for: newValue)
                    }
                    invalidateFunction()
                }

                LabeledField(title: "Log group", symbol: "text.alignleft") {
                    SetupTextField("/aws/lambda/sri-txt-robot", text: $draft.logGroupName)
                }
                .onChange(of: draft.logGroupName) { _, _ in invalidateFunction() }
            }

            if let function {
                HStack(spacing: 10) {
                    Circle()
                        .fill(function.isActive ? Palette.green : Palette.amber)
                        .frame(width: 8, height: 8)
                    Text("\(function.functionName) · \(function.healthText)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(function.memorySize ?? 0) MB · \(function.timeout ?? 0) s")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(10)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            Text("La app solo invoca la función. La construcción y publicación de la imagen sigue siendo responsabilidad del repositorio sri-txt-robot.")
                .font(.system(size: 8.5))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func invalidateFunction() {
        function = nil
        errorMessage = nil
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                KeyValueRow(key: "Cuenta", value: identity?.account ?? "—", monospaced: true)
                KeyValueRow(key: "Identidad", value: identity?.displayName ?? "—")
                KeyValueRow(key: "Región", value: draft.region, monospaced: true)
                KeyValueRow(key: "Función", value: function?.functionName ?? draft.functionName, monospaced: true)
                KeyValueRow(key: "Log group", value: draft.logGroupName, monospaced: true)
            }
            .padding(14)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Toggle(isOn: $notificationsEnabled) {
                SettingDescription(
                    title: "Recibir notificaciones de macOS",
                    detail: "Un aviso cuando una ejecución termine con errores."
                )
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 6) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 9))
                Text("Preferencias e historial se guardan dentro de la app; los secretos en el Llavero.")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Palette.textSecondary)
        }
    }

    private func feature(symbol: String, tint: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func testCredentials() {
        errorMessage = nil
        testing = true
        Task {
            do {
                identity = try await engine.validateCredentials(draft: draft)
            } catch {
                identity = nil
                errorMessage = error.localizedDescription
            }
            testing = false
        }
    }

    private func testFunction() {
        errorMessage = nil
        testing = true
        Task {
            do {
                function = try await engine.validateFunction(draft: draft)
            } catch {
                function = nil
                errorMessage = error.localizedDescription
            }
            testing = false
        }
    }

    private func save() {
        guard let identity, let function else { return }
        errorMessage = nil
        saving = true
        let validation = AWSValidation(identity: identity, function: function, validatedAt: Date())
        Task {
            do {
                try await engine.saveInitialSetup(
                    draft: draft,
                    validation: validation,
                    notificationsEnabled: notificationsEnabled
                )
                saving = false
            } catch {
                saving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
