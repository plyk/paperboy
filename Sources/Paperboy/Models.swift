import Foundation

struct Feed: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var tags: [String] = []
    var isEnabled = true
    var lastFetched: Date?
    var lastError: String?
    var lastItemCount: Int?
    /// A cikkek teljes szövegét a weboldalukról tölti le (sok hírcsatorna csak kivonatot ad).
    var fetchFullText = false
}

extension Feed {
    /// Hiányzó kulcsoknál az alapértéket használja, így egy új mező nem teszi olvashatatlanná a régi fájlt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastFetched = try container.decodeIfPresent(Date.self, forKey: .lastFetched)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastItemCount = try container.decodeIfPresent(Int.self, forKey: .lastItemCount)
        fetchFullText = try container.decodeIfPresent(Bool.self, forKey: .fetchFullText) ?? false
    }
}

struct AppSettings: Codable, Equatable {
    /// Mappa a tableten, pl. "Hírek" vagy "Hírek/Reggeli". Üres = gyökér.
    var targetFolder = "Hírek"
    /// A tablet címe; USB-kábelen mindig 10.11.99.1.
    var tabletHost = RemarkableUSB.defaultHost
    var transport = TransportKind.usbWeb
    /// Csak SSH-n: a régi, jegyzet nélküli kiadások áthelyezése a Kukába.
    var trashOldEditions = false
    var keepEditionsDays = 7
    var maxArticlesPerFeed = 10
    var maxAgeDays = 2
    var includeImages = true
    var autoSyncOnConnect = true
    var autoSyncSchedule = AutoSyncSchedule.daily
    /// Napi szinkronnál ennél korábban nem indul (óra, helyi idő szerint).
    var dailySyncHour = 6
    var notifyAfterAutoSync = true
}

enum AutoSyncSchedule: String, Codable, CaseIterable {
    case everyConnection
    case daily
}

extension AppSettings {
    /// Hiányzó kulcsoknál az alapértéket használja, így egy új beállítás nem teszi olvashatatlanná a régi fájlt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        targetFolder = try container.decodeIfPresent(String.self, forKey: .targetFolder) ?? defaults.targetFolder
        tabletHost = try container.decodeIfPresent(String.self, forKey: .tabletHost) ?? defaults.tabletHost
        transport = try container.decodeIfPresent(TransportKind.self, forKey: .transport) ?? defaults.transport
        trashOldEditions = try container.decodeIfPresent(Bool.self, forKey: .trashOldEditions) ?? defaults.trashOldEditions
        keepEditionsDays = try container.decodeIfPresent(Int.self, forKey: .keepEditionsDays) ?? defaults.keepEditionsDays
        maxArticlesPerFeed = try container.decodeIfPresent(Int.self, forKey: .maxArticlesPerFeed) ?? defaults.maxArticlesPerFeed
        maxAgeDays = try container.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? defaults.maxAgeDays
        includeImages = try container.decodeIfPresent(Bool.self, forKey: .includeImages) ?? defaults.includeImages
        autoSyncOnConnect = try container.decodeIfPresent(Bool.self, forKey: .autoSyncOnConnect) ?? defaults.autoSyncOnConnect
        autoSyncSchedule = try container.decodeIfPresent(AutoSyncSchedule.self, forKey: .autoSyncSchedule) ?? defaults.autoSyncSchedule
        dailySyncHour = try container.decodeIfPresent(Int.self, forKey: .dailySyncHour) ?? defaults.dailySyncHour
        notifyAfterAutoSync = try container.decodeIfPresent(Bool.self, forKey: .notifyAfterAutoSync) ?? defaults.notifyAfterAutoSync
    }
}

struct SyncState: Codable {
    /// "címke|cikk-azonosító" → mikor került fel a tabletre
    var uploaded: [String: Date] = [:]
    /// "címke|nap" → hány kiadás készült aznap
    var editions: [String: Int] = [:]
    /// Utolsó sikeres feltöltés a tabletre.
    var lastSync: Date?
    /// SSH-n létrehozott kiadások a tableten: azonosító → létrehozás ideje (a régiek takarításához).
    var createdDocuments: [String: Date]?
    /// Mikor kérdeztünk rá utoljára a régi kiadások takarítására (legfeljebb hetente kérdezünk).
    var lastCleanupPrompt: Date?
}

struct Article: Identifiable {
    var id: String
    var feedID: Feed.ID
    var title: String
    var link: String?
    var published: Date?
    var author: String?
    var html: String
    var feedName: String
    /// A hírcsatorna saját vezetőképe (enclosure / media:content).
    var leadImageURL: String?
    /// Helyőrző sorszáma → beágyazandó kép (lásd `HTMLCleaner`).
    var images: [Int: ArticleImage] = [:]
}

/// Szürkeárnyalatos, a tablet felbontására kicsinyített JPEG.
struct ArticleImage {
    let jpeg: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

enum Tags {
    /// Címke nélküli hírforrások ebbe a kiadásba kerülnek.
    static let untagged = "Egyéb"

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func effective(_ feed: Feed) -> [String] {
        feed.tags.isEmpty ? [untagged] : feed.tags
    }
}
