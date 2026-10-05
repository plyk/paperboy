import Foundation
import Network

/// Feltöltés SSH-n, közvetlenül a tablet dokumentumtárába (xochitl).
///
/// Minden dokumentum egy `<uuid>.pdf`, egy `<uuid>.content` és egy `<uuid>.metadata` fájl; a mappák csak
/// `.metadata`-t és `.content`-et kapnak. Az új fájlokat a tablet felülete újraindítás után látja.
///
/// Belépés: a root jelszóval egyszer feltelepítünk egy saját SSH-kulcsot (`installKey`), onnantól a
/// kapcsolat kulccsal megy, a jelszót nem tároljuk. A macOS beépített `ssh`/`ssh-keygen` parancsait használjuk.
final class RemarkableSSH: TabletTransport {
    enum SSHError: LocalizedError {
        case unreachable(host: String)
        case keyNotInstalled
        case hostKeyChanged
        case authenticationFailed
        case command(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let host):
                "A tablet nem érhető el SSH-n a(z) \(host) címen. Ellenőrizd a kábelt (vagy Wi-Fi-n a címet), és hogy a tablet fel van-e oldva."
            case .keyNotInstalled:
                "A Paperboy kulcsa még nincs telepítve a tabletre. A Beállításokban add meg a root jelszót, és telepítsd a kulcsot."
            case .hostKeyChanged:
                "A tablet SSH-azonosítója megváltozott (pl. gyári visszaállítás után). Telepítsd újra a kulcsot a Beállításokban."
            case .authenticationFailed:
                "Hibás jelszó, vagy a tablet elutasította a belépést."
            case .command(let message):
                "SSH-hiba: \(message)"
            }
        }
    }

    static let defaultDirectory = "/home/root/.local/share/remarkable/xochitl"

    let host: String
    let port: Int
    let user: String
    /// A tablet dokumentumtára.
    let directory: String
    /// Ezzel indítjuk újra a tablet felületét, hogy betöltse az új dokumentumokat.
    let restartCommand: String
    var unreachableError: Error { SSHError.unreachable(host: host) }

    private var folderID = ""
    /// Történt-e módosítás, amely miatt újra kell indítani a tablet felületét.
    private var needsRestart = false

    init(host: String, port: Int = 22, user: String = "root", directory: String = defaultDirectory,
         restartCommand: String = "systemctl restart xochitl") {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        self.host = trimmed.isEmpty ? RemarkableUSB.defaultHost : trimmed
        self.port = port
        self.user = user
        self.directory = directory
        self.restartCommand = restartCommand
    }

    // MARK: - TabletTransport

    func isReachable() async -> Bool {
        await Self.canConnect(host: host, port: UInt16(clamping: port), timeout: 3)
    }

    func test(folder: String) async throws -> String {
        let entries = try await listEntries()
        if try await resolveFolder(folder, in: entries, create: false) != nil {
            return "✓ SSH-kapcsolat rendben, a célmappa megvan."
        }
        return "✓ SSH-kapcsolat rendben. A célmappa még nincs meg, az első szinkronizálás létrehozza."
    }

    func prepare(folder: String) async throws {
        let entries = try await listEntries()
        folderID = try await resolveFolder(folder, in: entries, create: true) ?? ""
    }

    func upload(_ pdf: Data, name: String) async throws -> String? {
        let id = UUID().uuidString.lowercased()
        // A metadata kerül fel utoljára: a tablet csak akkor látja a dokumentumot, ha a PDF már ott van.
        try await write(pdf, to: "\(id).pdf")
        try await write(Self.json(["fileType": "pdf"]), to: "\(id).content")
        try await write(Self.metadata(name: name, type: "DocumentType", parent: folderID), to: "\(id).metadata")
        needsRestart = true
        return id
    }

    func finish() async throws {
        guard needsRestart else { return }
        try await restartInterface()
    }

    /// Van-e olyan változás a tableten, amely csak a felület újraindítása után látszik.
    var hasPendingChanges: Bool { needsRestart }

    /// A tablet felületének újraindítása (pár másodperc), hogy betöltse az új dokumentumokat.
    func restartInterface() async throws {
        try await run(restartCommand)
        needsRestart = false
    }

    // MARK: - Régi kiadások

    struct TrashResult {
        /// Ezekkel végeztünk (áthelyezve, jegyzetelt, vagy már nem létezik), nem kell tovább követni.
        var handled: [String] = []
        var trashed = 0
        var annotated = 0
    }

    /// A megadott dokumentumokat a Kukába helyezi, ha nincs bennük kézírásos jegyzet; a jegyzetelteket meghagyja.
    func moveToTrash(_ ids: [String]) async throws -> TrashResult {
        var result = TrashResult()
        for id in ids where id.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let path = "\(directory)/\(id)"
            // A jegyzetek a <uuid>/ mappában .rm fájlként vannak.
            let check = try await run("if [ ! -f \(path).metadata ]; then echo missing; " +
                                      "elif find \(path) -name '*.rm' 2>/dev/null | grep -q .; then echo annotated; " +
                                      "else cat \(path).metadata; fi")
            let output = check.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if output == "missing" || output == "annotated" {
                result.handled.append(id)
                if output == "annotated" { result.annotated += 1 }
                continue
            }
            guard var metadata = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            else { continue }
            metadata["parent"] = "trash"
            metadata["lastModified"] = Self.timestamp()
            metadata["metadatamodified"] = true
            try await write(Self.json(metadata), to: "\(id).metadata")
            needsRestart = true
            result.handled.append(id)
            result.trashed += 1
        }
        return result
    }

    // MARK: - Mappák

    private struct Entry {
        let id: String
        let name: String
        let parent: String
        let isFolder: Bool
    }

    private func listEntries() async throws -> [Entry] {
        // Soronként: azonosító, tabulátor, a .metadata tartalma egy sorba vonva.
        // `find`, nem `*.metadata`: így bármelyik shellben működik, üres mappánál is.
        let script = "cd \(directory) && find . -maxdepth 1 -name '*.metadata' | while read -r f; do " +
            "printf '%s\\t' \"$(basename \"$f\" .metadata)\"; tr -d '\\n' < \"$f\"; echo; done"
        let output = try await run(script)
        return output.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let json = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
                  json["deleted"] as? Bool != true
            else { return nil }
            return Entry(id: String(parts[0]), name: json["visibleName"] as? String ?? "",
                         parent: json["parent"] as? String ?? "",
                         isFolder: json["type"] as? String == "CollectionType")
        }
    }

    /// A mappa azonosítója az útvonal alapján ("Hírek/Reggeli"); üres útvonal = gyökér ("").
    private func resolveFolder(_ path: String, in entries: [Entry], create: Bool) async throws -> String? {
        var parent = ""
        let components = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for component in components {
            if let existing = entries.first(where: {
                $0.isFolder && $0.parent == parent && $0.name.compare(component, options: .caseInsensitive) == .orderedSame
            }) {
                parent = existing.id
                continue
            }
            guard create else { return nil }
            let id = UUID().uuidString.lowercased()
            try await write(Self.json([:]), to: "\(id).content")
            try await write(Self.metadata(name: component, type: "CollectionType", parent: parent), to: "\(id).metadata")
            needsRestart = true
            parent = id
        }
        return parent
    }

    // MARK: - Fájlformátum

    private static func metadata(name: String, type: String, parent: String) -> Data {
        let now = timestamp()
        return json([
            "createdTime": now,
            "deleted": false,
            "lastModified": now,
            "lastOpened": "0",
            "lastOpenedPage": 0,
            "metadatamodified": false,
            "modified": false,
            "parent": parent,
            "pinned": false,
            "synced": false,
            "type": type,
            "version": 0,
            "visibleName": name,
        ])
    }

    /// Ezredmásodperc szövegként, ahogy a tablet tárolja.
    private static func timestamp() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: - SSH

    /// Fájl írása a dokumentumtárba; a fájlnév csak azonosítóból és kiterjesztésből áll, így nem kell idézni.
    private func write(_ data: Data, to filename: String) async throws {
        try await run("cat > \(directory)/\(filename)", input: data)
    }

    @discardableResult
    private func run(_ command: String, input: Data? = nil) async throws -> ProcessRunner.Output {
        let keys = try SSHKeys.prepare()
        guard FileManager.default.fileExists(atPath: keys.privateKey.path) else { throw SSHError.keyNotInstalled }
        let output = try await ProcessRunner.run("/usr/bin/ssh", keys.options(authentication: .key) +
                                                 ["-p", String(port), "\(user)@\(host)", command], input: input, timeout: 120)
        guard output.succeeded else { throw Self.error(from: output, host: host) }
        return output
    }

    private static func error(from output: ProcessRunner.Output, host: String) -> SSHError {
        let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || message.contains("Host key verification failed") {
            return .hostKeyChanged
        }
        if message.contains("Permission denied") { return .keyNotInstalled }
        if message.contains("timed out") || message.contains("Connection refused") || message.contains("No route") {
            return .unreachable(host: host)
        }
        return .command(message.isEmpty ? "kilépési kód \(output.status)" : message)
    }

    /// A Paperboy kulcsának telepítése a root jelszóval. A jelszót csak erre az egy hívásra adjuk át az `ssh`-nak.
    static func installKey(host: String, port: Int = 22, user: String = "root", password: String) async throws {
        let keys = try SSHKeys.prepare()
        try await keys.generateIfNeeded()
        // Új telepítésnél (pl. gyári visszaállítás után) a tablet azonosítóját is újra elfogadjuk.
        let knownHost = port == 22 ? host : "[\(host)]:\(port)"
        _ = try? await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", knownHost, "-f", keys.knownHosts.path])

        let publicKey = try String(contentsOf: keys.publicKey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // A kulcsot a szabványos bemeneten adjuk át, így nem kell parancssorba idézni.
        let addKey = "key=$(cat); umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; " +
            "grep -qxF \"$key\" ~/.ssh/authorized_keys || echo \"$key\" >> ~/.ssh/authorized_keys"
        let output = try await ProcessRunner.run(
            "/usr/bin/ssh", keys.options(authentication: .password) + ["-p", String(port), "\(user)@\(host)", addKey],
            input: Data((publicKey + "\n").utf8),
            environment: [
                "SSH_ASKPASS": keys.askpass.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": ":0",
                "PAPERBOY_SSH_PASSWORD": password,
            ],
            timeout: 30)
        guard output.succeeded else {
            let error = error(from: output, host: host)
            if case .keyNotInstalled = error { throw SSHError.authenticationFailed }
            throw error
        }
    }

    /// TCP-kapcsolódási próba a 22-es portra, belépés nélkül.
    private static func canConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { result in
                once.run {
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// Gondoskodik róla, hogy egy művelet csak egyszer fusson le, akárhány szálról hívják.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// A Paperboy saját SSH-kulcsa és beállításai (~/Library/Application Support/Paperboy/ssh).
struct SSHKeys {
    enum Authentication { case key, password }

    let directory: URL
    var privateKey: URL { directory.appendingPathComponent("id_ed25519") }
    var publicKey: URL { directory.appendingPathComponent("id_ed25519.pub") }
    var knownHosts: URL { directory.appendingPathComponent("known_hosts") }
    var askpass: URL { directory.appendingPathComponent("askpass.sh") }

    static func prepare() throws -> SSHKeys {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paperboy/ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return SSHKeys(directory: directory)
    }

    var hasKey: Bool { FileManager.default.fileExists(atPath: privateKey.path) }

    func generateIfNeeded() async throws {
        if !hasKey {
            let output = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-q",
                                                                             "-C", "paperboy", "-f", privateKey.path])
            guard output.succeeded else { throw RemarkableSSH.SSHError.command(output.stderr) }
        }
        // A jelszót környezeti változóból olvassa ki; a fájlban nincs titok.
        try Data("#!/bin/sh\nprintf '%s\\n' \"$PAPERBOY_SSH_PASSWORD\"\n".utf8).write(to: askpass)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
    }

    func options(authentication: Authentication) -> [String] {
        var options = [
            // Idézőjelben, mert az ssh szóközöknél több fájlra bontaná ("Application Support").
            "-o", "UserKnownHostsFile=\"\(knownHosts.path)\"",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=5",
            "-o", "LogLevel=ERROR",
            // Régebbi tablet-firmware-ek SSH-szervere csak ezt az algoritmust ismerheti.
            "-o", "HostKeyAlgorithms=+ssh-rsa",
        ]
        switch authentication {
        case .key:
            options += [
                "-i", privateKey.path,
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
            ]
        case .password:
            options += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        }
        return options
    }
}
