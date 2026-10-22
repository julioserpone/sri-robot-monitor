import Foundation

/// Nodo del árbol de un bucket de S3: una carpeta con hijos o un archivo.
///
/// Es una estructura pura (sin SwiftUI) porque el árbol se construye a partir
/// de claves planas y conviene probarlo con las rutas reales del robot:
/// `facturas-recibidas/produccion/2026/09/raw/0102/archivo.txt`.
struct BucketNode: Identifiable, Hashable, Sendable {
    /// Ruta completa dentro del bucket. Para una carpeta termina en `/`.
    let path: String
    let name: String
    let isFolder: Bool
    /// Tamaño en bytes, solo en archivos y solo si S3 lo devuelve.
    var size: Int?
    var lastModified: Date?
    var children: [BucketNode]

    var id: String { path }

    /// Tipo de archivo según la extensión; las carpetas no tienen.
    var kind: DownloadKind? {
        guard !isFolder else { return nil }
        return path.lowercased().hasSuffix(".txt") ? .txt : .json
    }

    init(
        path: String,
        name: String,
        isFolder: Bool,
        size: Int? = nil,
        lastModified: Date? = nil,
        children: [BucketNode] = []
    ) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.lastModified = lastModified
        self.children = children
    }

    /// Convierte las claves planas de `ListObjectsV2` en un árbol.
    ///
    /// Los objetos se agrupan por prefijo intermedio; el resultado se ordena
    /// con carpetas primero y luego por nombre, que es como se lee una ruta.
    static func build(from objects: [S3Object]) -> [BucketNode] {
        var root: [String: BucketNode] = [:]
        for object in objects {
            root = inserting(object.key, into: root, leaf: object)
        }
        return sort(Array(root.values))
    }

    /// Todas las hojas del árbol, en orden de lectura.
    var files: [BucketNode] {
        isFolder ? children.flatMap(\.files) : [self]
    }

    /// Busca un nodo por ruta, para el explorador de la barra lateral.
    func node(at path: String) -> BucketNode? {
        if self.path == path { return self }
        for child in children {
            if let found = child.node(at: path) { return found }
        }
        return nil
    }

    /// Inserta una clave en el árbol.
    ///
    /// `prefix` acumula las carpetas ya recorridas, porque cada nodo necesita su
    /// ruta **absoluta**: `2026/` dentro de producción es `produccion/2026/`, y
    /// con el nombre suelto dos ramas distintas se fusionarían.
    ///
    /// Devuelve el nivel en lugar de tomarlo `inout`, y avanza quitando el
    /// primer tramo del camino: recursar con la clave completa no termina nunca
    /// (stack overflow, exit 132).
    private static func inserting(
        _ rest: String,
        prefix: String = "",
        into level: [String: BucketNode],
        leaf: S3Object? = nil
    ) -> [String: BucketNode] {
        var level = level
        let absolute = prefix + rest
        guard let separator = rest.firstIndex(of: "/") else {
            level[absolute] = BucketNode(
                path: absolute,
                name: rest,
                isFolder: false,
                size: leaf?.size,
                lastModified: leaf?.lastModified
            )
            return level
        }

        let folderPath = prefix + String(rest[rest.startIndex...separator])
        let folderName = String(rest[..<separator])
        let remainder = String(rest[rest.index(after: separator)...])
        var folder = level[folderPath] ?? BucketNode(
            path: folderPath,
            name: folderName,
            isFolder: true
        )

        guard !remainder.isEmpty else {
            // La clave termina en `/`: carpeta marcador del bucket.
            level[folderPath] = folder
            return level
        }

        let nested = Dictionary(uniqueKeysWithValues: folder.children.map { ($0.path, $0) })
        let updated = inserting(remainder, prefix: folderPath, into: nested, leaf: leaf)
        folder.children = sort(Array(updated.values))
        level[folderPath] = folder
        return level
    }

    private static func sort(_ nodes: [BucketNode]) -> [BucketNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}


