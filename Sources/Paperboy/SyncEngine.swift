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
        /// Miért vár a tablet felülete újraindításra (nil: nem vár).
        var restartReason: RestartReason?
    }

    enum RestartReason {
        /// Közvetlenül írt dokumentumok vagy új mappa: csak újraindítás után látszanak.
        case newDocuments
        /// Régi kiadások Kukába helyezése; ehhez is újra kell indítani a felületet.
        case cleanup
    }

    private struct Edition {
        let tag: String
        let articles: [Article]
    }

    @Published private(set) var isRunning = false
    @Published private(set) var log: [LogLine] = []
    /// A tablet felületének újraindítása a felhasználó jóváhagyására vár.
    @Published private(set) var restartReason: RestartReason?
    var restartPending: Bool { restartReason != nil }

    private let store: FeedStore
    private let extractor = FullTextExtractor()
    /// Az előnézet és a szinkronizálás között ne kelljen ugyanazt újra letölteni.
    private var fullTextCache: [URL: FullTextExtractor.Extracted] = [:]
    private var lastAutoSync: Date?
    private let autoSyncCooldown: TimeInterval = 10 * 60

    private let notifications = NotificationHandler()

    init(store: FeedStore) {
        self.store = store
        notifications.onRestartRequested = { [weak self] in
            Task { await self?.restartTabletInterface() }
        }
        notifications.activate()
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

        let summary = await run(.upload, deferRestart: true)
        // Az újraindításhoz jóváhagyás kell, ezért erről mindig szólunk.
        switch summary.restartReason {
        case .newDocuments:
            Self.notify(title: "Friss hírek a tableten",
                        body: "\(summary.editions) kiadás, \(summary.articles) cikk felkerült. A megjelenítésükhöz a tablet felülete pár másodpercre újraindul.",
                        category: NotificationHandler.restartCategory)
            return
        case .cleanup:
            let uploaded = summary.editions > 0 ? "\(summary.editions) kiadás felkerült. " : ""
            Self.notify(title: summary.editions > 0 ? "Friss hírek a tableten" : "Régi kiadások takarítása",
                        body: uploaded + "A régi kiadások a Kukába tehetők; ehhez a tablet felülete pár másodpercre újraindul.",
                        category: NotificationHandler.restartCategory)
            return
        case nil:
            break
        }
        guard store.settings.notifyAfterAutoSync else { return }
        if let error = summary.error {
            Self.notify(title: "A szinkronizálás nem sikerült", body: error)
        } else if summary.editions > 0 {
            Self.notify(title: "Friss hírek a tableten",
                        body: "\(summary.editions) kiadás, összesen \(summary.articles) cikk feltöltve.")
        }
    }

    @discardableResult
    /// - Parameter deferRestart: SSH-n ne indítsa újra magától a tablet felületét (automatikus szinkron).
    func run(_ mode: Mode, deferRestart: Bool = false) async -> Summary {
        guard !isRunning else { return Summary() }
        isRunning = true
        defer { isRunning = false }
        log.removeAll()
        var summary = Summary()

        do {
            let folder = store.settings.targetFolder
            var transport: TabletTransport?
            if mode == .upload {
                let connection = store.settings.makeTransport()
                note("Kapcsolódás a tablethez (\(store.settings.transport == .ssh ? "SSH" : "USB web interface"), \(connection.host))…")
                guard await connection.isReachable() else { throw connection.unreachableError }
                try await connection.prepare(folder: folder)
                transport = connection
                note("Célmappa: \(folder.isEmpty ? "(gyökér)" : folder)")
                if let ssh = connection as? RemarkableSSH {
                    if let problem = ssh.webInterfaceProblem { note(problem, isError: true) }
                    note(ssh.uploadsViaWebInterface
                         ? "Feltöltés a web interface-en, újraindítás nélkül."
                         : "A web interface nem érhető el (vagy új mappa készült): a kiadások közvetlenül kerülnek a tabletre, és a felület újraindítása után látszanak.")
                }
            }

            let articles = await fetchAll()
            var editions = buildEditions(from: articles, includeUploaded: mode == .preview)
            guard !editions.isEmpty else {
                note("Nincs új cikk.")
                if let transport {
                    summary.restartReason = try await finishUpload(transport, deferRestart: deferRestart)
                    store.syncState.lastSync = Date()
                }
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
                    guard let transport else { break }
                    if let id = try await transport.upload(pdf, name: name) {
                        store.syncState.createdDocuments = (store.syncState.createdDocuments ?? [:])
                            .merging([id: now]) { _, new in new }
                    }
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

            if let transport {
                summary.restartReason = try await finishUpload(transport, deferRestart: deferRestart)
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

    private static func notify(title: String, body: String, category: String? = nil) {
        // `swift run`-nál nincs alkalmazáscsomag, ott az értesítési központ nem használható.
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// A feltöltés lezárása. Visszaadja, ha a tablet felülete újraindításra vár.
    ///
    /// SSH-n a közvetlenül írt dokumentumok (és egy újonnan létrehozott mappa) csak újraindítás után látszanak:
    /// kézi szinkronnál ez azonnal megtörténik, `deferRestart` esetén jóváhagyásra vár. A web interface-en
    /// feltöltött kiadások azonnal látszanak; ilyenkor újraindításra csak a régi kiadások takarításához lenne
    /// szükség, erre legfeljebb hetente kérdezünk rá. Futó felület mellett a dokumentumok adatait nem
    /// módosítjuk, mert a tablet felülírhatná, ezért a takarítás mindig az újraindítással együtt történik.
    private func finishUpload(_ transport: TabletTransport, deferRestart: Bool) async throws -> RestartReason? {
        guard let ssh = transport as? RemarkableSSH else {
            try await transport.finish()
            return nil
        }
        if ssh.hasPendingChanges || (!deferRestart && restartReason == .newDocuments) {
            if deferRestart {
                restartReason = .newDocuments
                note("Az új kiadások a tableten vannak; a felület újraindítása után jelennek meg.")
                return restartReason
            }
            try await trashOldEditions(ssh)
            note("A tablet felületének újraindítása…")
            try await ssh.restartInterface()
            restartReason = nil
            return nil
        }
        if restartReason == nil, isCleanupDue {
            restartReason = .cleanup
            store.syncState.lastCleanupPrompt = Date()
            note("Régi kiadások várnak a Kukába helyezésre; ehhez a tablet felületét újra kell indítani (menüsor vagy eszköztár).")
        }
        return restartReason
    }

    /// A takarításhoz kijelölt (a beállított napnál régebbi) kiadások.
    private var cleanupCandidates: [String: Date] {
        guard store.settings.trashOldEditions else { return [:] }
        let limit = Date().addingTimeInterval(-Double(store.settings.keepEditionsDays) * 86_400)
        return (store.syncState.createdDocuments ?? [:]).filter { $0.value < limit }
    }

    /// Akkor kérdezünk rá a takarításra, ha már egy hétnyi régi kiadás gyűlt össze, és egy hete nem kérdeztünk.
    private var isCleanupDue: Bool {
        let week: TimeInterval = 7 * 86_400
        guard let oldest = cleanupCandidates.values.min(),
              Date().timeIntervalSince(oldest) > Double(store.settings.keepEditionsDays) * 86_400 + week
        else { return false }
        return store.syncState.lastCleanupPrompt.map { Date().timeIntervalSince($0) > week } ?? true
    }

    /// A függőben lévő újraindítás végrehajtása (az értesítés gombjáról vagy a menüből).
    func restartTabletInterface() async {
        guard !isRunning else { return }
        guard let ssh = store.settings.makeTransport() as? RemarkableSSH else {
            restartReason = nil
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            guard await ssh.isReachable() else { throw ssh.unreachableError }
            try await trashOldEditions(ssh)
            note("A tablet felületének újraindítása…")
            try await ssh.restartInterface()
            note(restartReason == .cleanup ? "Kész." : "Kész, az új kiadások megjelentek a tableten.")
            restartReason = nil
        } catch {
            note(error.localizedDescription, isError: true)
            Self.notify(title: "A tablet felülete nem indult újra", body: error.localizedDescription)
        }
    }

    private func trashOldEditions(_ ssh: RemarkableSSH) async throws {
        let old = Array(cleanupCandidates.keys)
        guard !old.isEmpty else { return }
        let result = try await ssh.moveToTrash(old)
        for id in result.handled { store.syncState.createdDocuments?[id] = nil }
        if result.trashed > 0 { note("\(result.trashed) régi kiadás a Kukába került.") }
        if result.annotated > 0 { note("\(result.annotated) régi kiadás maradt a helyén, mert jegyzet van benne.") }
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
