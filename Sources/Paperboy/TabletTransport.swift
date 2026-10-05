import Foundation

/// A tabletre való feltöltés módja.
enum TransportKind: String, Codable, CaseIterable {
    /// USB web interface (http://10.11.99.1) – nincs hozzá szükség jelszóra.
    case usbWeb
    /// SSH root-hozzáféréssel: mappát is létrehoz, és Wi-Fi-n is működhet.
    case ssh
}

/// Közös felület a két feltöltési módhoz.
protocol TabletTransport {
    var host: String { get }
    var unreachableError: Error { get }

    /// Gyors ellenőrzés, hogy a tablet elérhető-e (a csatlakozásfigyelő 15 másodpercenként hívja).
    func isReachable() async -> Bool
    /// A kapcsolatteszt eredménye; nem módosít semmit a tableten.
    func test(folder: String) async throws -> String
    /// Feltöltés előtti előkészítés (USB-n a célmappa ellenőrzése, SSH-n szükség esetén létrehozása).
    func prepare(folder: String) async throws
    /// Egy kiadás feltöltése a célmappába; a tableten létrejött dokumentum azonosítója, ha ismert.
    func upload(_ pdf: Data, name: String) async throws -> String?
    /// A feltöltések lezárása (SSH-n a tablet felületének újraindítása, hogy megjelenjenek a dokumentumok).
    func finish() async throws
}

extension AppSettings {
    func makeTransport() -> TabletTransport {
        switch transport {
        case .usbWeb: RemarkableUSB(host: tabletHost)
        case .ssh: RemarkableSSH(host: tabletHost)
        }
    }
}

extension RemarkableUSB: TabletTransport {
    var unreachableError: Error { USBError.unreachable(host: host) }

    func test(folder: String) async throws -> String {
        try await enterFolder(path: folder)
        return "✓ A tablet elérhető, a célmappa megvan."
    }

    func prepare(folder: String) async throws {
        self.folder = folder
        try await enterFolder(path: folder)
    }

    func upload(_ pdf: Data, name: String) async throws -> String? {
        // A feltöltés a legutóbb listázott mappába kerül, ezért minden feltöltés előtt belépünk.
        try await enterFolder(path: folder)
        try await upload(pdf, filename: "\(name).pdf")
        return nil
    }

    func finish() async throws {}
}
