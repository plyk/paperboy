import SwiftUI

struct ContentView: View {
    enum SidebarItem: Hashable {
        case all
        case tag(String)
    }

    @EnvironmentObject private var store: FeedStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var tablet: TabletMonitor
    @State private var sidebar: SidebarItem? = .all
    @State private var selection = Set<Feed.ID>()
    @State private var editing: Feed?
    @State private var showLog = true

    private var visibleFeeds: [Feed] {
        switch sidebar {
        case .tag(let tag): store.feeds(tagged: tag)
        default: store.feeds
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                Label("Összes hírforrás", systemImage: "tray.full")
                    .badge(store.feeds.count)
                    .tag(SidebarItem.all)
                Section("Címkék") {
                    ForEach(store.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .badge(store.feeds(tagged: tag).count)
                            .tag(SidebarItem.tag(tag))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                if store.feeds.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Még nincs hírforrás")
                        } icon: {
                            Image(nsImage: PaperboyLogo.image(height: 56))
                        }
                    } description: {
                        Text("Adj hozzá egy RSS- vagy Atom-hírcsatornát, és címkézd fel. Minden címkéből napi PDF-kiadás készül a tabletre.")
                    } actions: {
                        Button("Új hírforrás") { addFeed() }
                    }
                } else {
                    feedTable
                }
                if showLog {
                    Divider()
                    LogView()
                        .frame(height: 130)
                }
            }
        }
        .toolbar { toolbar }
        .sheet(item: $editing) { feed in
            FeedEditor(feed: feed)
        }
    }

    private var feedTable: some View {
        Table(visibleFeeds, selection: $selection) {
            TableColumn("Aktív") { feed in
                Toggle("Aktív", isOn: enabledBinding(feed.id))
                    .labelsHidden()
            }
            .width(40)
            TableColumn("Név") { feed in
                HStack(spacing: 4) {
                    Text(feed.name)
                    if feed.fetchFullText {
                        Image(systemName: "doc.plaintext")
                            .foregroundStyle(.secondary)
                            .help("Teljes cikk letöltése a weboldalról")
                    }
                }
            }
            TableColumn("Címkék") { feed in
                Text(feed.tags.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            TableColumn("URL") { feed in
                Text(feed.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Állapot") { feed in
                FeedStatus(feed: feed)
            }
        }
        .contextMenu(forSelectionType: Feed.ID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Szerkesztés…") { edit(id) }
            }
            Button("Törlés", role: .destructive) { store.delete(ids) }
        } primaryAction: { ids in
            if let id = ids.first { edit(id) }
        }
        .onDeleteCommand { store.delete(selection) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Label(tablet.isConnected ? "Tablet csatlakoztatva" : "Tablet nincs csatlakoztatva",
                  systemImage: tablet.isConnected ? "cable.connector" : "cable.connector.slash")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(tablet.isConnected ? .primary : .secondary)
                .help(store.syncState.lastSync.map {
                    "Utolsó szinkronizálás: \($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "Még nem volt szinkronizálás")
        }
        ToolbarItemGroup {
            Button { addFeed() } label: {
                Label("Új hírforrás", systemImage: "plus")
            }
            .help("Új hírforrás hozzáadása")

            Button { showLog.toggle() } label: {
                Label("Napló", systemImage: "list.bullet.rectangle")
            }
            .help("Napló megjelenítése/elrejtése")

            SettingsLink {
                Label("Beállítások", systemImage: "gearshape")
            }

            Button { Task { await sync.run(.preview) } } label: {
                Label("Előnézet", systemImage: "doc.text.magnifyingglass")
            }
            .help("A kiadások PDF-jének elkészítése helyben, feltöltés nélkül")
            .disabled(sync.isRunning || store.feeds.isEmpty)

            Button { Task { await sync.run(.upload) } } label: {
                if sync.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Szinkronizálás", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .help("Új cikkek feltöltése a tabletre USB-n")
            .disabled(sync.isRunning || store.feeds.isEmpty)
        }
    }

    private func addFeed() {
        var feed = Feed(name: "", url: "")
        if case .tag(let tag) = sidebar, tag != Tags.untagged { feed.tags = [tag] }
        editing = feed
    }

    private func edit(_ id: Feed.ID) {
        editing = store.feeds.first { $0.id == id }
    }

    private func enabledBinding(_ id: Feed.ID) -> Binding<Bool> {
        Binding {
            store.feeds.first { $0.id == id }?.isEnabled ?? false
        } set: { value in
            if let index = store.feeds.firstIndex(where: { $0.id == id }) {
                store.feeds[index].isEnabled = value
            }
        }
    }
}

private struct FeedStatus: View {
    let feed: Feed

    var body: some View {
        if let error = feed.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(error)
        } else if let fetched = feed.lastFetched {
            Text("\(feed.lastItemCount ?? 0) cikk · \(fetched.formatted(.relative(presentation: .named)))")
                .foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

private struct LogView: View {
    @EnvironmentObject private var sync: SyncEngine

    var body: some View {
        if sync.log.isEmpty {
            Text("A szinkronizálás eseményei itt jelennek meg.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(sync.log) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(line.text)
                            .foregroundStyle(line.isError ? .red : .primary)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    .id(line.id)
                }
                .onChange(of: sync.log.count) {
                    if let last = sync.log.last { proxy.scrollTo(last.id) }
                }
            }
        }
    }
}
