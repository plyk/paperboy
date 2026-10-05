import SwiftUI

@main
struct PaperboyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: FeedStore
    @StateObject private var sync: SyncEngine
    @StateObject private var tablet: TabletMonitor

    init() {
        let store = FeedStore()
        let sync = SyncEngine(store: store)
        let tablet = TabletMonitor(store: store)
        tablet.onAvailable = { [weak sync] newlyConnected in
            Task { await sync?.autoSync(newlyConnected: newlyConnected) }
        }
        tablet.start()
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: sync)
        _tablet = StateObject(wrappedValue: tablet)
    }

    var body: some Scene {
        Window("Paperboy", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(sync)
                .environmentObject(tablet)
                .frame(minWidth: 780, minHeight: 440)
                // Nyitott ablaknál legyen Dock-ikon, bezárva csak a menüsorban él tovább.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
        }
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(sync)
                .environmentObject(tablet)
        } label: {
            Image(nsImage: PaperboyLogo.menuBarImage(isSyncing: sync.isRunning))
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var store: FeedStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var tablet: TabletMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(tablet.isConnected ? "Tablet csatlakoztatva" : "Tablet nincs csatlakoztatva")
        if let lastSync = store.syncState.lastSync {
            Text("Utolsó szinkronizálás: \(lastSync.formatted(.relative(presentation: .named)))")
        }
        if sync.isRunning {
            Text("Szinkronizálás folyamatban…")
        } else if let status = sync.autoSyncStatus {
            Text(status)
        }
        Divider()
        Button("Szinkronizálás most") { Task { await sync.run(.upload) } }
            .disabled(sync.isRunning || !tablet.isConnected)
        Button("Előnézet") { Task { await sync.run(.preview) } }
            .disabled(sync.isRunning)
        Divider()
        Button("Hírforrások…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Beállítások…") }
        Divider()
        Button("Kilépés") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run`-nal indítva is legyen rendes, előtérbe kerülő alkalmazás.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Az ablak bezárása után a menüsorban fut tovább, hogy csatlakozáskor szinkronizálni tudjon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
