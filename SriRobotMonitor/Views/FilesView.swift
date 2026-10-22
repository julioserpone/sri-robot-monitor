import AppKit
import SwiftUI

/// Explorador del bucket configurado: árbol de carpetas, búsqueda y descarga.
///
/// No es un `OutlineGroup` plegable: con las rutas del robot
/// (`facturas-recibidas/produccion/2026/09/raw/0102/…`) plegar cuatro niveles
/// para llegar a un archivo es más lento que verlos abiertos y buscar. Por eso
/// se muestran todas las carpetas expandidas, con indentación por nivel.
struct FilesView: View {
    @Environment(MonitorEngine.self) private var engine
    @State private var query = ""
    /// Carpetas plegadas. El árbol nace abierto: plegar es la excepción.
    @State private var collapsed: Set<String> = []
    @State private var downloading: String?
    @State private var message: String?
    @State private var error: String?

    private var bucketConfigured: Bool { !engine.configuration.bucketName.isEmpty }

    private var visibleNodes: [BucketRow] {
        guard let root = engine.bucketTree.first else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if term.isEmpty {
            return BucketRow.flatten(root, collapsed: collapsed)
                .filter { $0.node.isFolder || isRelevant($0.node) }
        }

        // Con búsqueda se muestran solo las ramas que contienen coincidencias,
        // con sus carpetas padre para conservar el contexto de la ruta.
        return BucketRow.filtered(root, term: term)
            .filter { $0.node.isFolder || isRelevant($0.node) }
            .map { row in
                var copy = row
                copy.depth = 0
                return copy
            }
    }

    private var matchCount: Int {
        visibleNodes.filter { !$0.node.isFolder }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(.white.opacity(0.06))
            content
        }
        .task { await engine.loadBucketTree() }
        .onChange(of: engine.configuration.bucketName) { _, _ in
            Task { await engine.loadBucketTree(force: true) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                TextField("Filtrar por carpeta, período o archivo (2026, raw, .txt)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 4)

            if !query.isEmpty {
                Text("\(matchCount) archivo(s)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
            }

            Button {
                Task { await engine.loadBucketTree(force: true) }
            } label: {
                HStack(spacing: 5) {
                    if engine.bucketLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(engine.bucketLoading ? "Leyendo…" : "Actualizar")
                }
                .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(engine.bucketLoading || !bucketConfigured)

            Button("Expandir todo") {
                collapsed = []
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(engine.bucketTree.isEmpty || collapsed.isEmpty)

            Button("Plegar todo") {
                collapsed = Set(engine.bucketTree.flatMap(\.allFolderPaths))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(engine.bucketTree.isEmpty)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if !bucketConfigured {
            empty(
                symbol: "externaldrive.badge.questionmark",
                title: "Sin bucket configurado",
                message: "Indica el bucket en Ajustes → Conexión para explorar los archivos del robot."
            )
        } else if let bucketError = engine.bucketError {
            empty(symbol: "exclamationmark.triangle", title: "No se pudo leer el bucket", message: bucketError)
        } else if engine.bucketLoading, engine.bucketTree.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Listando s3://\(engine.configuration.bucketName)…")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleNodes.isEmpty {
            empty(
                symbol: query.isEmpty ? "tray" : "magnifyingglass",
                title: query.isEmpty ? "El bucket está vacío" : "Ningún archivo coincide",
                message: query.isEmpty
                    ? "s3://\(engine.configuration.bucketName) no tiene objetos."
                    : "Prueba con otra palabra: un período (2026-09), una carpeta (raw) o una extensión (.txt)."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleNodes) { row in
                        BucketRowView(
                            row: row,
                            isExpanded: row.node.isFolder ? isExpanded(row.node) : false,
                            isDownloading: downloading == row.node.path,
                            message: message,
                            error: error,
                            onToggle: { toggle(row.node) },
                            onDownload: { download(row.node) }
                        )
                        Divider().overlay(.white.opacity(0.035))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
        }
    }

    /// El bucket puede contener cualquier cosa; el explorador prioriza lo que
    /// produce el robot. Las extensiones desconocidas se ocultan para no llenar
    /// la vista de ruido.
    private func isRelevant(_ node: BucketNode) -> Bool {
        let name = node.name.lowercased()
        return name.hasSuffix(".txt") || name.hasSuffix(".json")
            || name.hasSuffix(".pdf") || name.hasSuffix(".xml") || name.hasSuffix(".zip")
    }

    private func empty(symbol: String, title: String, message: String) -> some View {
        EmptyStateView(symbol: symbol, title: title, message: message)
            .frame(maxHeight: .infinity)
    }

    private func isExpanded(_ node: BucketNode) -> Bool {
        !collapsed.contains(node.path)
    }

    private func toggle(_ node: BucketNode) {
        if collapsed.contains(node.path) {
            collapsed.remove(node.path)
        } else {
            collapsed.insert(node.path)
        }
    }

    private func download(_ node: BucketNode) {
        guard !node.isFolder else { return }
        error = nil
        message = nil
        downloading = node.path
        let object = S3Object(bucket: engine.configuration.bucketName, key: node.path)
        Task {
            do {
                if try await engine.download(object) {
                    message = "Guardado \(node.name)."
                }
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
        }
    }
}

/// Una fila ya aplanada del árbol: el nodo y su profundidad de indentación.
struct BucketRow: Identifiable {
    var node: BucketNode
    var depth: Int

    var id: String { node.path }

    /// Recorre el árbol respetando qué carpetas están plegadas.
    static func flatten(_ node: BucketNode, collapsed: Set<String>, depth: Int = 0) -> [BucketRow] {
        var rows = [BucketRow(node: node, depth: depth)]
        if node.isFolder, !collapsed.contains(node.path) {
            for child in node.children {
                rows.append(contentsOf: flatten(child, collapsed: collapsed, depth: depth + 1))
            }
        }
        return rows
    }

    /// Ramas que contienen la búsqueda, con sus carpetas padre.
    static func filtered(_ node: BucketNode, term: String) -> [BucketRow] {
        let matches = node.isFolder
            ? node.name.lowercased().contains(term) || node.path.lowercased().contains(term)
            : node.name.lowercased().contains(term) || node.path.lowercased().contains(term)

        if !node.isFolder {
            return matches ? [BucketRow(node: node, depth: 0)] : []
        }

        if matches {
            // Una carpeta que coincide muestra todo su contenido.
            return [BucketRow(node: node, depth: 0)] + node.children.flatMap { child in
                flatten(child, collapsed: [], depth: 1)
            }
        }

        let children = node.children.flatMap { filtered($0, term: term) }
        guard !children.isEmpty else { return [] }
        let withParents = children.map { row -> BucketRow in
            var copy = row
            copy.depth += 1
            return copy
        }
        return [BucketRow(node: node, depth: 0)] + withParents
    }
}

private struct BucketRowView: View {
    let row: BucketRow
    let isExpanded: Bool
    let isDownloading: Bool
    let message: String?
    let error: String?
    let onToggle: () -> Void
    let onDownload: () -> Void
    @State private var hovering = false

    private var node: BucketNode { row.node }

    var body: some View {
        HStack(spacing: 8) {
            if node.isFolder {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12)
            }

            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 15)

            Text(node.name)
                .font(.system(size: 10.5, weight: node.isFolder ? .semibold : .regular))
                .foregroundStyle(node.isFolder ? .white.opacity(0.9) : .white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if let date = node.lastModified {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }

            if let size = node.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(width: 62, alignment: .trailing)
            } else if node.isFolder {
                Text("\(node.files.count) archivo(s)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }

            if !node.isFolder {
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        if isDownloading {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text("Descargar")
                    }
                    .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.glassProminent)
                .tint(node.kind == .txt ? Palette.blue : Palette.violet)
                .foregroundStyle(.black.opacity(0.82))
                .controlSize(.small)
                .disabled(isDownloading)
                .opacity(hovering || isDownloading ? 1 : 0.55)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(hovering ? .white.opacity(0.03) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            if !node.isFolder {
                Button("Descargar…", action: onDownload)
                Button("Copiar ruta") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                }
            }
        }
    }

    private var symbol: String {
        if node.isFolder { return isExpanded ? "folder.fill" : "folder" }
        switch node.path.lowercased().suffix(4) {
        case ".txt": return "doc.plaintext"
        case "json": return "curlybraces"
        default: return "doc"
        }
    }

    private var tint: Color {
        if node.isFolder { return Palette.amber }
        return node.path.lowercased().hasSuffix(".txt") ? Palette.blue : Palette.violet
    }
}

extension BucketNode {
    /// Rutas de todas las carpetas, para «Expandir todo».
    var allFolderPaths: [String] {
        isFolder ? [path] + children.flatMap(\.allFolderPaths) : []
    }
}
