import Foundation

/// A reMarkable USB web interface kliense (Beállítások → Tárhely → USB web interface).
/// A feltöltés abba a mappába kerül, amelyet legutóbb listáztunk, ezért feltöltés előtt
/// mindig belépünk a célmappába. Mappát létrehozni ezen a felületen nem lehet.
final class RemarkableUSB {
    struct Item {
        let id: String
        let name: String
        let isFolder: Bool
    }

    static let defaultHost = "10.11.99.1"

    enum USBError: LocalizedError {
        case unreachable(host: String)
        case folderNotFound(String)
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let host):
                "A tablet nem érhető el a(z) \(host) címen. Csatlakoztasd USB-n, oldd fel, és kapcsold be a Beállítások → Tárhely → USB web interface opciót."
            case .folderNotFound(let name):
                "A(z) „\(name)” mappa nem létezik a tableten. Hozd létre a tableten, mert USB-n keresztül nem lehet mappát létrehozni."
            case .http(let code):
                "A tablet HTTP \(code) hibát adott."
            case .badResponse:
                "A tablet válasza nem értelmezhető."
            }
        }
    }

    let host: String
    private var base: String { "http://\(host)" }
    /// A `prepare(folder:)` óta használt célmappa.
    var folder = ""
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    init(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        self.host = trimmed.isEmpty ? Self.defaultHost : trimmed
    }

    func isReachable() async -> Bool {
        (try? await list(folderID: nil, timeout: 3)) != nil
    }

    func list(folderID: String?, timeout: TimeInterval = 15) async throws -> [Item] {
        guard let url = URL(string: "\(base)/documents/\(folderID ?? "")") else { throw USBError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw USBError.unreachable(host: host)
        }
        try check(response)
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw USBError.badResponse
        }
        return entries.compactMap { entry in
            guard let id = entry["ID"] as? String else { return nil }
            // A firmware valóban "VissibleName"-et küld.
            let name = entry["VissibleName"] as? String ?? entry["VisibleName"] as? String ?? ""
            return Item(id: id, name: name, isFolder: entry["Type"] as? String == "CollectionType")
        }
    }

    /// Belép a megadott útvonalú mappába ("Hírek/Reggeli"); üres útvonal = gyökér.
    func enterFolder(path: String) async throws {
        var items = try await list(folderID: nil)
        let components = path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for component in components {
            guard let folder = items.first(where: {
                $0.isFolder && $0.name.compare(component, options: [.caseInsensitive]) == .orderedSame
            }) else { throw USBError.folderNotFound(component) }
            items = try await list(folderID: folder.id)
        }
    }

    func upload(_ pdf: Data, filename: String) async throws {
        guard let url = URL(string: "\(base)/upload") else { throw USBError.badResponse }
        let boundary = "Paperboy-\(UUID().uuidString)"
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(pdf)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(base, forHTTPHeaderField: "Origin")
        request.setValue(base + "/", forHTTPHeaderField: "Referer")
        let (_, response) = try await session.upload(for: request, from: body)
        try check(response)
    }

    private func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw USBError.http(http.statusCode)
        }
    }
}
