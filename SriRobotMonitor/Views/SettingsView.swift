import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var draft = RobotConfiguration.default
    @State private var environmentDraft = RobotEnvironment()
    @State private var showingSecrets = false
    @State private var environmentSaving = false
    @State private var environmentMessage: String?
    @State private var environmentError: String?
    @State private var loaded = false
    @State private var showingRevalidate = false
    @State private var showingReset = false
    @State private var saving = false
    @State private var saveError: String?

    private var isDirty: Bool {
        draft != engine.configuration
    }

    private var isEnvironmentDirty: Bool {
        environmentDraft != engine.environment
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preferencias de la app")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("Los cambios de conexión reinician la lectura de CloudWatch.")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.red)
                            .lineLimit(1)
                    }
                    Button {
                        save()
                    } label: {
                        HStack(spacing: 6) {
                            if saving { ProgressView().controlSize(.small) }
                            Text(saving ? "Guardando…" : "Guardar cambios")
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.green)
                    .controlSize(.regular)
                    .disabled(!isDirty || saving)
                }

                connectionCard
                robotKeysCard
                notificationsCard
                credentialsCard
                dataCard
                aboutCard
            }
            .padding(26)
        }
        .onAppear {
            guard !loaded else { return }
            draft = engine.configuration
            environmentDraft = engine.environment
            loaded = true
        }
        .onChange(of: engine.configuration) { _, newValue in
            if !saving { draft = newValue }
        }
        .onChange(of: engine.environment) { _, newValue in
            if !environmentSaving { environmentDraft = newValue }
        }
        .task {
            await engine.loadFunctionEnvironmentKeys()
        }
        .sheet(isPresented: $showingRevalidate) {
            RevalidateCredentialsSheet()
                .environment(engine)
        }
        .alert("Restablecer la aplicación", isPresented: $showingReset) {
            Button("Cancelar", role: .cancel) {}
            Button("Borrar todo", role: .destructive) {
                Task { try? await engine.resetApplication() }
            }
        } message: {
            Text("Se eliminarán las credenciales del Llavero, las preferencias y el historial local. La función de AWS no se toca.")
        }
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(
                    title: "Conexión con AWS",
                    subtitle: "Región, función de Lambda y log group",
                    symbol: "network"
                )

                HStack(alignment: .top, spacing: 14) {
                    LabeledField(title: "Región", symbol: "globe.americas.fill") {
                        HStack(spacing: 6) {
                            TextField("us-east-1", text: $draft.region)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, design: .monospaced))
                            Menu {
                                ForEach(AWSRegions.common, id: \.self) { region in
                                    Button(region) { draft.region = region }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 16)
                        }
                    }

                    LabeledField(title: "Función de Lambda", symbol: "server.rack") {
                        TextField("sri-txt-robot", text: $draft.functionName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .onChange(of: draft.functionName) { oldValue, newValue in
                        if draft.logGroupName == RobotConfiguration.defaultLogGroup(for: oldValue) {
                            draft.logGroupName = RobotConfiguration.defaultLogGroup(for: newValue)
                        }
                    }

                    LabeledField(title: "Log group", symbol: "text.alignleft") {
                        TextField("/aws/lambda/sri-txt-robot", text: $draft.logGroupName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    LabeledField(title: "Bucket S3 (opcional)", symbol: "externaldrive") {
                        TextField("facturas-recibidas", text: $draft.bucketName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    LabeledField(title: "Ambiente en S3", symbol: "folder") {
                        TextField("produccion", text: $draft.environmentName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                Text("El bucket permite descargar el TXT y el JSON de cada ejecución desde el detalle de la ejecución.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Palette.textSecondary)

                Divider().overlay(.white.opacity(0.05))

                HStack(spacing: 18) {
                    if let identity = engine.callerIdentity {
                        InfoPill(symbol: "person.crop.circle", text: identity.displayName)
                        InfoPill(symbol: "number", text: "Cuenta \(identity.account)")
                    } else {
                        InfoPill(symbol: "exclamationmark.triangle", text: "Sin identidad validada", tint: Palette.amber)
                    }

                    if let function = engine.functionInfo {
                        InfoPill(
                            symbol: "bolt.horizontal.circle",
                            text: "\(function.functionName) · \(function.healthText)",
                            tint: function.isActive ? Palette.green : Palette.amber
                        )
                    }

                    Spacer()

                    Button {
                        showingRevalidate = true
                    } label: {
                        Label("Revalidar credenciales AWS", systemImage: "checkmark.shield")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }

    private var notificationsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(
                    title: "Alertas y supervisión",
                    subtitle: "Cómo y cuándo avisarte",
                    symbol: "bell.badge.fill"
                )

                Toggle(isOn: $draft.notificationsEnabled) {
                    SettingDescription(
                        title: "Notificaciones de macOS",
                        detail: "Avisa al terminar una ejecución con errores y si se pierde la supervisión."
                    )
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: draft.notificationsEnabled) { _, enabled in
                    if enabled, !engine.notificationsAuthorized {
                        Task { await engine.requestNotificationPermission() }
                    }
                }

                Toggle(isOn: $draft.notifyWarnings) {
                    SettingDescription(
                        title: "Avisar también advertencias",
                        detail: "El LED se pone naranja y también llega una notificación."
                    )
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!draft.notificationsEnabled)

                Divider().overlay(.white.opacity(0.05))

                HStack(spacing: 8) {
                    Image(systemName: engine.isLiveTailing ? "dot.radiowaves.left.and.right" : "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(engine.isLiveTailing ? Palette.green : Palette.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lectura en tiempo real")
                            .font(.system(size: 11, weight: .semibold))
                        Text(engine.isLiveTailing
                            ? "CloudWatch envía cada línea al instante (Live Tail)."
                            : "Live Tail no está disponible; sondeo cada \(draft.pollIntervalSeconds) s.")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Text(engine.isLiveTailing ? "Activo" : "Respaldo")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(engine.isLiveTailing ? Palette.green : Palette.amber)
                }

                Divider().overlay(.white.opacity(0.05))

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frecuencia de respaldo")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Cada cuánto se consulta CloudWatch si Live Tail falla.")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Picker("", selection: $draft.pollIntervalSeconds) {
                        Text("2 s").tag(2)
                        Text("4 s").tag(4)
                        Text("6 s").tag(6)
                        Text("10 s").tag(10)
                        Text("30 s").tag(30)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 82)

                    Text("Historial")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    Picker("", selection: $draft.historyDays) {
                        Text("7 días").tag(7)
                        Text("14 días").tag(14)
                        Text("30 días").tag(30)
                        Text("45 días").tag(45)
                        Text("90 días").tag(90)
                        Text("365 días").tag(365)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                if !engine.notificationsAuthorized, draft.notificationsEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 9))
                        Text("macOS no ha autorizado las notificaciones de esta app.")
                            .font(.system(size: 9))
                        Button("Abrir Ajustes") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 9))
                    }
                    .foregroundStyle(Palette.amber)
                }
            }
        }
    }

    /// Claves que la app adjunta al evento en modo `tail`. Viven en el Llavero,
    /// no en la configuración de la función, así que rotarlas no necesita
    /// permisos de Lambda ni un redeploy.
    private var robotKeysCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(
                        title: "Claves del robot",
                        subtitle: "Se envían en el evento, en el Llavero de macOS",
                        symbol: "key.viewfinder"
                    )
                    Spacer()
                    Toggle(isOn: $showingSecrets) {
                        Text("Mostrar")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                HStack(alignment: .top, spacing: 12) {
                    secretField(
                        title: RobotEnvironment.portalPasswordVariable,
                        placeholder: "Clave del portal del SRI",
                        text: $environmentDraft.portalPassword
                    )
                    secretField(
                        title: RobotEnvironment.anticaptchaVariable,
                        placeholder: "Clave de anti-captcha",
                        text: $environmentDraft.anticaptchaKey
                    )
                }

                LabeledField(title: "Perfil de Chrome (opcional)", symbol: "person.crop.square") {
                    TextField("perfil_dir de la imagen (por ejemplo /app/perfil)", text: $environmentDraft.profileDirectory)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                }

                if !engine.functionEnvironmentKeys.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.blue)
                        Text("La función declara: \(engine.functionEnvironmentKeys.sorted().joined(separator: ", "))")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                    }
                }

                if let environmentError {
                    Text(environmentError)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.red)
                        .textSelection(.enabled)
                }
                if let environmentMessage {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Palette.green)
                        Text(environmentMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.green)
                    }
                }

                HStack {
                    Text("Se usan cuando activas «Esperar el resultado» al relanzar (modo tail).")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button {
                        saveEnvironment()
                    } label: {
                        HStack(spacing: 6) {
                            if environmentSaving { ProgressView().controlSize(.small) }
                            Text(environmentSaving ? "Guardando…" : "Guardar claves")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.blue)
                    .controlSize(.small)
                    .disabled(!isEnvironmentDirty || environmentSaving)
                }
            }
        }
    }

    private func secretField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        LabeledField(title: title, symbol: "lock.fill") {
            Group {
                if showingSecrets {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
        }
    }

    private var credentialsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(
                    title: "Credenciales",
                    subtitle: "Guardadas en el Llavero de macOS, nunca en el JSON",
                    symbol: "key.horizontal.fill"
                )

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Access Key ID")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Palette.textSecondary)
                        Text(engine.credentials?.maskedAccessKeyID ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Última validación")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Palette.textSecondary)
                        Text(engine.lastValidationAt?.formatted(date: .abbreviated, time: .shortened) ?? "Sin validar")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let error = engine.keychainError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.red)
                }

                Text("La app usa AWS Signature V4 con acceso directo a STS, Lambda y CloudWatch Logs (sondeo y Live Tail). No necesita el CLI de AWS instalado.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.textSecondary)

                HStack {
                    Button {
                        showingRevalidate = true
                    } label: {
                        Label("Revalidar o cambiar credenciales", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.blue)
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private var dataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(
                    title: "Datos dentro de la app",
                    subtitle: "Preferencias, historial y caché de registros",
                    symbol: "internaldrive.fill"
                )

                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Palette.amber)
                    Text(engine.dataDirectoryPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Abrir carpeta") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: engine.dataDirectoryPath))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                HStack {
                    Button("Borrar historial local") {
                        Task { await engine.clearHistory() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Spacer()

                    Button("Restablecer aplicación") {
                        showingReset = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(Palette.red)
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            HStack(spacing: 16) {
                AppMark(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SRI Robot Monitor")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Interfaz nativa macOS con Liquid Glass para supervisar sri-txt-robot en AWS Lambda.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("v\(AppVersion.short) · MIT")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                    Link("Repositorio en GitHub", destination: URL(string: "https://github.com/julioserpone/sri-robot-monitor")!)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
    }

    private func save() {
        saveError = nil
        saving = true
        Task {
            do {
                try await engine.savePreferences(draft)
                draft = engine.configuration
                saving = false
            } catch {
                saving = false
                saveError = error.localizedDescription
            }
        }
    }

    private func saveEnvironment() {
        environmentError = nil
        environmentMessage = nil
        guard !environmentDraft.exceedsInvocationLimit else {
            environmentError = "Las claves superan el límite de 4 KB que Lambda acepta por invocación."
            return
        }
        environmentSaving = true
        Task {
            do {
                try await engine.saveEnvironment(environmentDraft)
                environmentDraft = engine.environment
                environmentMessage = "Claves guardadas en el Llavero."
            } catch {
                environmentError = error.localizedDescription
            }
            environmentSaving = false
        }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8))
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
            }
            .foregroundStyle(Palette.textSecondary)

            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingDescription: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoPill: View {
    let symbol: String
    let text: String
    var tint: Color = .white.opacity(0.62)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.035), in: .capsule)
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }
}
