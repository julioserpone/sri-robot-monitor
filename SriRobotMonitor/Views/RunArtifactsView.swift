import AppKit
import SwiftUI

/// Tarjeta con los archivos que dejó una ejecución en S3: el TXT que el robot
/// descargó del portal y el JSON con las claves extraídas.
///
/// Los objetos se buscan al abrir la tarjeta, no en cada sondeo: listar S3
/// cuesta una llamada por carpeta y período.
struct RunArtifactsView: View {
    @Environment(MonitorEngine.self) private var engine
    let run: RobotRun

    @State private var loading = false
    @State private var downloading: DownloadKind?
    @State private var message: String?
    @State private var error: String?

    private var objects: [S3Object] { engine.artifacts[run.id] ?? [] }

    private var bucketConfigured: Bool {
        !engine.configuration.bucketName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(
                    title: "Archivos de la ejecución",
                    subtitle: bucketConfigured
                        ? "s3://\(engine.configuration.bucketName)"
                        : "Configura el bucket en Ajustes",
                    symbol: "folder.badge.arrow.down"
                )
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 5) {
                        if loading { ProgressView().controlSize(.small) }
                        Text(loading ? "Buscando…" : "Buscar archivos")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(loading)
            }

            if objects.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: bucketConfigured ? "tray" : "gear")
                        .font(.system(size: 11))
                        .foregroundStyle(bucketConfigured ? Palette.textSecondary : Palette.amber)
                    Text(
                        engine.artifactErrors[run.id]
                            ?? (bucketConfigured
                                ? "Pulsa «Buscar archivos» para localizar el TXT y el JSON de esta ejecución."
                                : "Indica el bucket de S3 en Ajustes → Conexión para poder descargar los archivos.")
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ForEach(objects) { object in
                    row(for: object)
                }
            }

            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.green)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.red)
                    .textSelection(.enabled)
            }
        }
        .task(id: run.id) {
            if objects.isEmpty, bucketConfigured, run.status == .healthy || run.status == .warning {
                await refresh()
            }
        }
    }

    private func row(for object: S3Object) -> some View {
        HStack(spacing: 10) {
            Image(systemName: object.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(object.kind == .txt ? Palette.blue : Palette.violet)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(object.kind.title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                Text(object.fileName)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button {
                download(object)
            } label: {
                HStack(spacing: 5) {
                    if downloading == object.kind {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("Descargar")
                }
                .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.glassProminent)
            .tint(object.kind == .txt ? Palette.blue : Palette.violet)
            .foregroundStyle(.black.opacity(0.82))
            .controlSize(.small)
            .disabled(downloading != nil)
        }
        .padding(9)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func refresh() async {
        loading = true
        message = nil
        error = nil
        engine.artifacts[run.id] = nil
        await engine.loadArtifacts(for: run)
        loading = false
        if let failure = engine.artifactErrors[run.id] {
            error = failure
        }
    }

    private func download(_ object: S3Object) {
        error = nil
        message = nil
        downloading = object.kind
        Task {
            do {
                let saved = try await engine.download(object)
                if saved {
                    message = "Guardado \(object.fileName)."
                }
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
        }
    }
}
