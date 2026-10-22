import Foundation
import XCTest
@testable import SriRobotMonitor

/// S3 rechaza toda petición sin `x-amz-content-sha256`
/// ("Missing required header for this request"), y la app no la enviaba.
final class S3SigningTests: XCTestCase {
    private let credentials = AWSCredentials(
        accessKeyID: TestCredential.exampleAccessKey,
        secretAccessKey: TestCredential.exampleSecret
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testEveryRequestCarriesContentSHA256() async throws {
        StubURLProtocol.configure { _ in (Self.response(200), Data("<ListBucketResult/>".utf8)) }

        _ = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).listObjects(bucket: "facturas-recibidas", prefix: "facturas-recibidas/")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        let header = try XCTUnwrap(
            request.value(forHTTPHeaderField: "x-amz-content-sha256"),
            "S3 exige la cabecera o responde con 400"
        )
        // Hash del cuerpo vacío: la petición de listado no lleva cuerpo.
        XCTAssertEqual(header, AWSSigner.sha256Hex(Data()))
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-content-sha256") ?? false,
            "La cabecera debe estar firmada, no solo enviada"
        )
    }

    func testBodyHashReflectsTheBody() async throws {
        StubURLProtocol.configure { _ in (Self.response(200), Data("datos".utf8)) }

        let payload = Data(#"{"periodos":["2026-09"]}"#.utf8)
        let client = AWSClient(credentials: credentials, region: "us-east-1", session: StubURLProtocol.session)
        _ = try? await client.send(service: .lambda, method: "POST", body: payload)

        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-amz-content-sha256"),
            AWSSigner.sha256Hex(payload)
        )
    }

    func testListingParsesSizesAndDates() async throws {
        let xml = """
        <ListBucketResult>
          <Contents>
            <Key>facturas-recibidas/produccion/2026/09/raw/0102/a.txt</Key>
            <LastModified>2026-10-20T15:04:05.000Z</LastModified>
            <Size>2048</Size>
          </Contents>
          <NextContinuationToken>tok-2</NextContinuationToken>
        </ListBucketResult>
        """
        StubURLProtocol.configure { _ in (Self.response(200), Data(xml.utf8)) }

        let page = try await S3Client(
            credentials: credentials,
            region: "us-east-1",
            session: StubURLProtocol.session
        ).listObjects(bucket: "b")

        XCTAssertEqual(page.objects.count, 1)
        XCTAssertEqual(page.objects[0].size, 2048)
        XCTAssertNotNil(page.objects[0].lastModified)
        XCTAssertEqual(page.nextToken, "tok-2")
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
        )!
    }
}

/// El árbol del explorador se construye con las rutas reales del robot.
final class BucketNodeTests: XCTestCase {
    private let robotKeys = [
        "facturas-recibidas/produccion/2026/09/raw/0102/202609_factura.txt",
        "facturas-recibidas/produccion/2026/09/manifest/0102/202609_claves.json",
        "facturas-recibidas/produccion/2026/08/raw/0102/202608_factura.txt",
        "facturas-recibidas/pruebas/2026/09/raw/0102/otra.txt"
    ]

    func testBuildNestsFoldersInOrder() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })

        XCTAssertEqual(tree.map(\.name), ["facturas-recibidas"])
        let root = tree[0]
        XCTAssertEqual(root.children.map(\.name), ["produccion", "pruebas"])

        let produccion = root.children[0]
        XCTAssertEqual(produccion.children.map(\.name), ["2026"])
        let year = produccion.children[0]
        XCTAssertEqual(year.children.map(\.name), ["08", "09"], "Los meses se ordenan como números, no como texto")
    }

    func testPathsAreAbsoluteAtEveryLevel() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })
        let leaf = tree[0].node(at: "facturas-recibidas/produccion/2026/09/raw/0102/202609_factura.txt")

        XCTAssertNotNil(leaf)
        XCTAssertEqual(leaf?.isFolder, false)
        XCTAssertEqual(leaf?.kind, .txt)
    }

    func testFilesCountIncludesNestedObjects() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })
        XCTAssertEqual(tree.flatMap(\.files).count, 4)
        XCTAssertEqual(tree[0].children[0].files.count, 3)
    }

    func testFoldersSortBeforeFiles() {
        let mixed = ["a/zeta.txt", "a/alpha.txt", "a/beta/c.txt"]
        let tree = BucketNode.build(from: mixed.map { S3Object(bucket: "b", key: $0) })

        XCTAssertEqual(tree[0].children.map(\.name), ["beta", "alpha.txt", "zeta.txt"])
    }

    func testDeletingNothingButDuplicateKeysAreStable() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })
        XCTAssertEqual(tree.count, 1, "Varias claves no deben duplicar la raíz")
    }

    // MARK: - Aplanado para la vista

    func testFlattenSkipsCollapsedFolders() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })
        let collapsed: Set<String> = ["facturas-recibidas/"]

        let rows = BucketRow.flatten(tree[0], collapsed: collapsed)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].node.path, "facturas-recibidas/")
    }

    func testFlattenOpensEverythingByDefault() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })
        let rows = BucketRow.flatten(tree[0], collapsed: [])

        // facturas-recibidas/ → produccion/ → 2026/ → 09/ → raw/ → 0102/
        let leaf = rows.first { $0.node.path.hasSuffix("202609_factura.txt") }
        XCTAssertEqual(leaf?.depth, 6, "Cada nivel de carpeta suma una indentación")
    }

    func testFilterKeepsParentFoldersAsContext() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })
        let rows = BucketRow.filtered(tree[0], term: "manifest")

        XCTAssertEqual(rows.first?.node.name, "facturas-recibidas")
        XCTAssertTrue(rows.contains { $0.node.name == "manifest" })
        XCTAssertFalse(rows.contains { $0.node.name.hasSuffix(".txt") }, "No debe colar archivos fuera del filtro")
    }

    func testFilterMatchesByExtensionAndPeriod() {
        let tree = BucketNode.build(from: robotKeys.map { S3Object(bucket: "b", key: $0) })

        let json = BucketRow.filtered(tree[0], term: ".json")
        XCTAssertEqual(json.filter { !$0.node.isFolder }.count, 1)

        let august = BucketRow.filtered(tree[0], term: "2026/08")
        XCTAssertTrue(august.contains { $0.node.path.contains("202608_factura.txt") })
    }
}
