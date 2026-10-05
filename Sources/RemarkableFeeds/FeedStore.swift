import Foundation

/// A hírforrások, beállítások és a szinkron-előzmények tárolója
/// (~/Library/Application Support/RemarkableFeeds/library.json).
@MainActor
final class FeedStore: ObservableObject {
    @Published var feeds: [Feed] = [] { didSet { save() } }
    @Published var settings = AppSettings() { didSet { save() } }
    @Published var syncState = SyncState() { didSet { save() } }

    private struct Library: Codable {
        var feeds: [Feed]
        var settings: AppSettings
        var syncState: SyncState
    }

    private let fileURL: URL
    private var isLoading = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemarkableFeeds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        load()
    }

    var allTags: [String] {
        Set(feeds.flatMap(Tags.effective)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func feeds(tagged tag: String) -> [Feed] {
        feeds.filter { Tags.effective($0).contains(tag) }
    }

    func upsert(_ feed: Feed) {
        if let index = feeds.firstIndex(where: { $0.id == feed.id }) {
            feeds[index] = feed
        } else {
            feeds.append(feed)
        }
    }

    func delete(_ ids: Set<Feed.ID>) {
        feeds.removeAll { ids.contains($0.id) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let library = try? decoder.decode(Library.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        feeds = library.feeds
        settings = library.settings
        syncState = library.syncState
    }

    private func save() {
        guard !isLoading else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let library = Library(feeds: feeds, settings: settings, syncState: syncState)
        guard let data = try? encoder.encode(library) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
