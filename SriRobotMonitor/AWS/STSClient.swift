import Foundation

struct STSClient: Sendable {
    let client: AWSClient

    init(credentials: AWSCredentials, region: String, session: URLSession = .shared) {
        client = AWSClient(credentials: credentials, region: region, session: session)
    }

    func getCallerIdentity() async throws -> CallerIdentity {
        let body = Data("Action=GetCallerIdentity&Version=2011-06-15".utf8)
        let response = try await client.send(
            service: .sts,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"],
            body: body
        )

        let parser = STSIdentityParser()
        let xml = XMLParser(data: response.data)
        xml.delegate = parser
        guard xml.parse(), let identity = parser.identity else {
            throw AWSAPIError(
                service: "STS",
                statusCode: response.statusCode,
                code: "InvalidResponse",
                message: "No se pudo leer la identidad devuelta por AWS."
            )
        }
        return identity
    }
}

private final class STSIdentityParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var buffer = ""
    private var account = ""
    private var arn = ""
    private var userID = ""

    var identity: CallerIdentity? {
        guard !account.isEmpty, !arn.isEmpty else { return nil }
        return CallerIdentity(account: account, arn: arn, userID: userID)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "Account": account = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "Arn": arn = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "UserId": userID = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
        currentElement = ""
        buffer = ""
    }
}
