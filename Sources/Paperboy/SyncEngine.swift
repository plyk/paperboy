import AppKit
import UserNotifications

@MainActor
final class SyncEngine: ObservableObject {
    enum Mode {
        /// PDF-ek feltöltése a tabletre, az előzmények frissítésével.
        case upload
        /// PDF-ek mentése helyben; az előzményeket nem módosítja.
        case preview
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        let isError: Bool
    }

    struct Summary {
        var editions = 0
        var articles = 0
        var error: String?
    }

    private struct Edition {
        let tag: String
        let articles: [Article]
    }

    @Published private(set) var isRunning = false
    @Published private(set) var log: [LogLine] = []

    private let store: FeedStore
    private var usb: RemarkableUSB { RemarkableUSB(host: store.settings.tabletHost) }
    private let extractor = FullTextExtractor()
    /// Az előnézet és a szinkronizálás között ne kelljen ugyanazt újra letölteni.
    private var fullTextCache: [URL: FullTextExtractor.Extracted] = [:]
    private var lastAutoSync: Date?
    private let autoSyncCooldown: TimeInterval = 10 * 60

    init(store: FeedStore) {
        self.store = store
    }

    /// Volt-e ma már sikeres feltöltés (kézi vagy automatikus).
    var hasSyncedToday: Bool {
        store.syncState.lastSync.map(Calendar.current.isDateInToday) ?? false
    }

    /// Rövid állapotszöveg a menüsorba az automatikus szinkronról.
    var autoSyncStatus: String? {
        let settings = store.settings
        guard settings.autoSyncOnConnect, settings.autoSyncSchedule == .daily else { return nil }
        if hasSyncedToday { return "A mai kiadás már a tableten van" }
        if Calendar.current.component(.hour, from: .now) < settings.dailySyncHour {
            return "Mai szinkronizálás \(settings.dailySyncHour):00-tól"
        }
        return "A mai szinkronizálás csatlakoztatáskor indul"
    }

    /// Automatikus szinkron, amíg a tablet elérhető (a `TabletMonitor` rendszeresen hívja).
    /// Az eredményről értesítést küld.
    func autoSync(newlyConnected: Bool) async {
        let settings = store.settings
        guard settings.autoSyncOnConnect, !isRunning, store.feeds.contains(where: \.isEnabled) else { return }
        switch settings.autoSyncSchedule {
        case .everyConnection:
            guard newlyConnected else { return }
        case .daily:
            guard !hasSyncedToday, Calendar.current.component(.hour, from: .now) >= settings.dailySyncHour else { return }
        }
        // Ki-be dugdosásnál, illetve hiba után ne próbálkozzon folyamatosan.
        if let lastAutoSync, Date().timeIntervalSince(lastAutoSync) < autoSyncCooldown { return }
        lastAutoSync = Date()

        let summary = await run(.upload)
        guard store.settings.notifyAfterAutoSync else { return }
        if let error = summary.error {
            Self.notify(title: "A szinkronizálás nem sikerült", body: error)
        } else if summary.editions > 0 {
            Self.notify(title: "Friss hírek a tableten",
                        body: "\(summary.editions) kiadás, összesen \(summary.articles) cikk feltöltve.")
        }
    }

    @discardableResult
    func run(_ mode: Mode) async -> Summary {
        guard !isRunning else { return Summary() }
        isRunning = true
        defer { isRunning = false }
        log.removeAll()
        var summary = Summary()

        do {
            let folder = store.settings.targetFolder
            if mode == .upload {
                note("Kapcsolódás a tablethez…")
                let usb = usb
                guard await usb.isReachable() else { throw RemarkableUSB.USBError.unreachable(host: usb.host) }
                try await usb.enterFolder(path: folder)
                note("Célmappa: \(folder.isEmpty ? "(gyökér)" : folder)")
            }

            let articles = await fetchAll()
            var editions = buildEditions(from: articles, includeUploaded: mode == .preview)
            guard !editions.isEmpty else {
                note("Nincs új cikk.")
                if mode == .upload { store.syncState.lastSync = Date() }
                return summary
            }

            editions = await loadFullText(editions)
            editions = await prepare(editions)

            let now = Date()
            let day = now.formatted(.iso8601.year().month().day())
            var previewFiles: [URL] = []
            let previewDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Paperboy-előnézet", isDirectory: true)
            if mode == .preview {
                try? FileManager.default.removeItem(at: previewDir)
                try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
            }

            for edition in editions {
                let editionKey = "\(edition.tag)|\(day)"
                let count = mode == .upload ? store.syncState.editions[editionKey, default: 0] : 0
                let name = "\(edition.tag) – \(day)" + (count > 0 ? " (\(count + 1))" : "")
                let pdf = EditionRenderer.render(title: edition.tag, date: now, articles: edition.articles)

                switch mode {
                case .upload:
                    try await usb.enterFolder(path: folder)
                    try await usb.upload(pdf, filename: "\(name).pdf")
                    for article in edition.articles {
                        store.syncState.uploaded["\(edition.tag)|\(article.id)"] = now
                    }
                    store.syncState.editions[editionKey] = count + 1
                case .preview:
                    let file = previewDir.appendingPathComponent("\(name).pdf")
                    try pdf.write(to: file)
                    previewFiles.append(file)
                }
                summary.editions += 1
                summary.articles += edition.articles.count
                note("✓ \(name) – \(edition.articles.count) cikk")
            }

            if mode == .upload {
                pruneHistory(today: day)
                store.syncState.lastSync = now
                note("Kész.")
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(previewFiles)
            }
        } catch {
            note(error.localizedDescription, isError: true)
            summary.error = error.localizedDescription
        }
        return summary
    }

    private static func notify(title: String, body: String) {
        // `swift run`-nál nincs alkalmazáscsomag, ott az értesítési központ nem használható.
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Lekéri az összes aktív hírforrást, és frissíti az állapotukat.
    private func fetchAll() async -> [Feed.ID: [Article]] {
        let feeds = store.feeds.filter(\.isEnabled)
        note("\(feeds.count) hírforrás lekérése…")

        let results = await withTaskGroup(of: (Feed, Result<ParsedFeed, Error>).self) { group in
            for feed in feeds {
                group.addTask {
                    do { return (feed, .success(try await FeedFetcher.fetch(feed.url))) }
                    catch { return (feed, .failure(error)) }
                }
            }
            var all: [(Feed, Result<ParsedFeed, Error>)] = []
            for await result in group { all.append(result) }
            return all
        }

        var articles: [Feed.ID: [Article]] = [:]
        for (feed, result) in results {
            guard let index = store.feeds.firstIndex(where: { $0.id == feed.id }) else { continue }
            store.feeds[index].lastFetched = Date()
            switch result {
            case .success(let parsed):
                store.feeds[index].lastError = nil
                store.feeds[index].lastItemCount = parsed.items.count
                articles[feed.id] = parsed.items.map {
                    Article(id: "\(feed.id.uuidString)|\($0.id)", feedID: feed.id, title: $0.title, link: $0.link,
                            published: $0.date, author: $0.author, html: $0.html, feedName: feed.name,
                            leadImageURL: $0.imageURL)
                }
            case .failure(let error):
                store.feeds[index].lastError = error.localizedDescription
                note("\(feed.name): \(error.localizedDescription)", isError: true)
            }
        }
        return articles
    }

    private func buildEditions(from articles: [Feed.ID: [Article]], includeUploaded: Bool) -> [Edition] {
        let settings = store.settings
        let cutoff = Date().addingTimeInterval(-Double(settings.maxAgeDays) * 86_400)
        var byTag: [String: [Article]] = [:]

        for feed in store.feeds where feed.isEnabled {
            guard let feedArticles = articles[feed.id] else { continue }
            let recent = feedArticles
                .filter { ($0.published ?? .now) >= cutoff }
                .sorted { ($0.published ?? .now) > ($1.published ?? .now) }
                .prefix(settings.maxArticlesPerFeed)
            for tag in Tags.effective(feed) {
                let fresh = recent.filter { includeUploaded || store.syncState.uploaded["\(tag)|\($0.id)"] == nil }
                byTag[tag, default: []] += fresh
            }
        }

        return byTag
            .filter { !$0.value.isEmpty }
            .map { Edition(tag: $0.key, articles: $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// Teljes szöveg a weboldalról azoknál a hírforrásoknál, ahol be van kapcsolva. Marad a hírcsatorna
    /// szövege, ha a kinyerés nem sikerül (pl. fizetős cikk), vagy az eredmény nem hosszabb annál.
    private func loadFullText(_ editions: [Edition]) async -> [Edition] {
        let feedIDs = Set(store.feeds.filter(\.fetchFullText).map(\.id))
        let links = Set(editions.flatMap(\.articles)
            .filter { feedIDs.contains($0.feedID) }
            .compactMap { $0.link.flatMap(URL.init(string:)) })
        guard !links.isEmpty else { return editions }

        note("\(links.count) cikk teljes szövegének letöltése…")
        let missing = links.subtracting(fullTextCache.keys)
        if !missing.isEmpty {
            fullTextCache.merge(await extractor.extract(missing)) { _, new in new }
        }

        var used = Set<URL>()
        let result = editions.map { edition in
            Edition(tag: edition.tag, articles: edition.articles.map { article in
                guard feedIDs.contains(article.feedID),
                      let url = article.link.flatMap(URL.init(string:)),
                      let extracted = fullTextCache[url],
                      extracted.textLength >= 300,
                      extracted.textLength > article.html.strippingTags.count
                else { return article }
                used.insert(url)
                var article = article
                article.html = extracted.html
                if article.author == nil { article.author = extracted.byline }
                return article
            })
        }
        let failed = links.count - used.count
        note("\(used.count) cikk teljes szövege letöltve" + (failed > 0 ? ", \(failed) esetben a hírcsatorna szövege maradt." : "."))
        return result
    }

    /// HTML tisztítása, és ha be van kapcsolva, a képek letöltése és beágyazásra előkészítése.
    private func prepare(_ editions: [Edition]) async -> [Edition] {
        let includeImages = store.settings.includeImages
        var imageURLs: [Article.ID: [URL]] = [:]
        let cleaned = editions.map { edition in
            Edition(tag: edition.tag, articles: edition.articles.map { article in
                var article = article
                let result = HTMLCleaner.clean(article.html, baseURL: article.link.flatMap { URL(string: $0) },
                                               keepImages: includeImages, leadImage: article.leadImageURL)
                article.html = result.html
                imageURLs[article.id] = result.imageURLs
                return article
            })
        }

        let allURLs = Set(imageURLs.values.joined())
        guard !allURLs.isEmpty else { return cleaned }
        note("\(allURLs.count) kép letöltése…")
        let images = await ImageLoader.load(allURLs)
        note("\(images.count) kép beillesztve" + (images.count < allURLs.count ? ", \(allURLs.count - images.count) nem sikerült." : "."))

        return cleaned.map { edition in
            Edition(tag: edition.tag, articles: edition.articles.map { article in
                var article = article
                for (index, url) in (imageURLs[article.id] ?? []).enumerated() {
                    article.images[index] = images[url]
                }
                return article
            })
        }
    }

    private func pruneHistory(today: String) {
        let keepDays = max(30, store.settings.maxAgeDays + 7)
        let limit = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        store.syncState.uploaded = store.syncState.uploaded.filter { $0.value >= limit }
        store.syncState.editions = store.syncState.editions.filter { $0.key.hasSuffix("|\(today)") }
    }

    private func note(_ text: String, isError: Bool = false) {
        log.append(LogLine(text: text, isError: isError))
    }
}
