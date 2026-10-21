import SwiftUI

struct RevalidateCredentialsSheet: View {
    @Environment(MonitorEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AWSSetupDraft()
    @State private var validation: AWSValidation?
    @State private var validatedDraft: AWSSetupDraft?
    @State private var testing = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var showSecrets = false
    @State private var initialized = false

    private var canSave: Bool {
        validation != nil && validatedDraft == draft && !saving && !testing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    credentialsForm
                    connectionForm
                    resultCard

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.red)
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.80))
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(12)
                        .background(Palette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 9))
                        Text("Las claves se guardan en el Llavero de macOS y no salen de tu equipo salvo para firmar las peticiones a AWS.")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Palette.textSecondary)
                }
                .padding(22)
            }

            Divider().overlay(.white.opacity(0.07))
            footer
        }
        .frame(width: 640, height: 720)
        .background(AuroraBackground())
        .interactiveDismissDisabled(saving)
        .task {
            guard !initialized else { return }
            draft = AWSSetupDraft.from(configuration: engine.configuration, credentials: engine.credentials)
            initialized = true
            await test()
        }
        .onChange(of: draft) { _, _ in
            errorMessage = nil
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.blue.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Revalidar credenciales AWS")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Comprueba la identidad, la función y el permiso de CloudWatch.")
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
            .disabled(saving)
        }
        .padding(22)
    }

    private var credentialsForm: some View {
        GlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Credenciales", subtitle: "IAM access key o credenciales temporales", symbol: "key.horizontal.fill")
                    Spacer()
                    Toggle(isOn: $showSecrets) {
                        Text("Mostrar")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                VStack(spacing: 10) {
                    LabeledField(title: "Access Key ID", symbol: "person.badge.key") {
                        TextField("AKIA…", text: $draft.accessKeyID)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    LabeledField(title: "Secret Access Key", symbol: "lock.fill") {
                        Group {
                            if showSecrets {
                                TextField("Secret Access Key", text: $draft.secretAccessKey)
                            } else {
                                SecureField("Secret Access Key", text: $draft.secretAccessKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                    }

                    LabeledField(title: "Session token (opcional)", symbol: "clock.badge.checkmark") {
                        Group {
                            if showSecrets {
                                TextField("Solo para credenciales temporales", text: $draft.sessionToken)
                            } else {
                                SecureField("Solo para credenciales temporales", text: $draft.sessionToken)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    private var connectionForm: some View {
        GlassCard(cornerRadius: 20, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Función del robot", subtitle: "La imagen publicada con el perfil caliente", symbol: "server.rack")

                HStack(alignment: .top, spacing: 10) {
                    LabeledField(title: "Región", symbol: "globe.americas.fill") {
                        TextField("us-east-1", text: $draft.region)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    LabeledField(title: "Función", symbol: "bolt.horizontal") {
                        TextField("sri-txt-robot", text: $draft.functionName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    LabeledField(title: "Log group", symbol: "text.alignleft") {
                        TextField("/aws/lambda/sri-txt-robot", text: $draft.logGroupName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if testing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Comprobando credenciales y permisos en AWS…")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            .padding(14)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let validation {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.green)
                    Text("Conexión válida")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    if validatedDraft != draft {
                        Text("Hay cambios sin probar")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.amber)
                    }
                }

                VStack(spacing: 6) {
                    KeyValueRow(key: "Cuenta", value: validation.identity.account, monospaced: true)
                    KeyValueRow(key: "Identidad", value: validation.identity.arn, monospaced: true)
                    KeyValueRow(key: "Función", value: "\(validation.function.functionName) · \(validation.function.healthText)")
                }
            }
            .padding(14)
            .background(Palette.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.green.opacity(0.15), lineWidth: 1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Permisos: sts:GetCallerIdentity, lambda:GetFunctionConfiguration, lambda:InvokeFunction, logs:FilterLogEvents.")
                .font(.system(size: 8.5))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: 320, alignment: .leading)

            Spacer()

            Button("Cancelar") { dismiss() }
                .buttonStyle(.glass)
                .disabled(saving)

            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 6) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Probando…" : "Probar conexión")
                }
            }
            .buttonStyle(.glass)
            .disabled(testing || saving)

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().controlSize(.small) }
                    Text(saving ? "Guardando…" : "Guardar")
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.green)
            .controlSize(.large)
            .disabled(!canSave)
        }
        .padding(18)
    }

    private func test() async {
        errorMessage = nil
        testing = true
        do {
            let result = try await engine.validate(draft: draft)
            validation = result
            validatedDraft = draft
        } catch {
            validation = nil
            validatedDraft = nil
            errorMessage = error.localizedDescription
        }
        testing = false
    }

    private func save() {
        guard let validation, validatedDraft == draft else { return }
        saving = true
        Task {
            do {
                try await engine.saveRevalidatedConnection(draft: draft, validation: validation)
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
