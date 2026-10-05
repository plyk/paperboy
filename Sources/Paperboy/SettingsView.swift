import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("reMarkable") {
                TextField("Célmappa", text: $store.settings.targetFolder, prompt: Text("pl. Hírek"))
                Text("A mappának léteznie kell a tableten, mert az USB-felületen keresztül nem lehet mappát létrehozni. Almappát így adhatsz meg: Hírek/Reggeli. Ha üresen hagyod, a gyökérbe kerül.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Kapcsolat tesztelése") { Task { await test() } }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.callout) }
                }
            }

            Section("Automatikus frissítés") {
                Toggle(isOn: $store.settings.autoSyncOnConnect) {
                    Text("Szinkronizálás a tablet csatlakoztatásakor")
                    Text("Amikor bedugod és feloldod a tabletet, az új kiadások maguktól felkerülnek. Az alkalmazás az ablak bezárása után a menüsorban fut tovább.")
                }
                if store.settings.autoSyncOnConnect {
                    Picker("Gyakoriság", selection: $store.settings.autoSyncSchedule) {
                        Text("Naponta egyszer").tag(AutoSyncSchedule.daily)
                        Text("Minden csatlakozáskor").tag(AutoSyncSchedule.everyConnection)
                    }
                    if store.settings.autoSyncSchedule == .daily {
                        Picker("Legkorábban", selection: $store.settings.dailySyncHour) {
                            ForEach(0..<13) { hour in Text("\(hour):00").tag(hour) }
                        }
                        Text("Naponta az első csatlakoztatáskor fut le, vagy a megadott időpontban, ha a tablet már be van dugva. A kézi szinkronizálás is beleszámít.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Értesítés az automatikus szinkronizálás után", isOn: $store.settings.notifyAfterAutoSync)
                    .disabled(!store.settings.autoSyncOnConnect)
                Toggle("Indítás bejelentkezéskor", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Kiadások") {
                Stepper("Legfeljebb \(store.settings.maxArticlesPerFeed) cikk hírforrásonként",
                        value: $store.settings.maxArticlesPerFeed, in: 1...50)
                Stepper("Csak az utolsó \(store.settings.maxAgeDays) nap cikkei",
                        value: $store.settings.maxAgeDays, in: 1...14)
                Toggle("Képek beillesztése (szürkeárnyalatosan)", isOn: $store.settings.includeImages)
            }

            Section("Előzmények") {
                LabeledContent("Feltöltött cikkek", value: "\(store.syncState.uploaded.count)")
                Button("Előzmények törlése") { store.syncState = SyncState() }
                Text("Törlés után a következő szinkronizálás újra feltölti a még friss cikkeket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Nem sikerült beállítani: \(error.localizedDescription). Másold az alkalmazást az Alkalmazások mappába, és próbáld újra."
            launchAtLogin = service.status == .enabled
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        do {
            try await RemarkableUSB().enterFolder(path: store.settings.targetFolder)
            testResult = "✓ A tablet elérhető, a célmappa megvan."
        } catch {
            testResult = error.localizedDescription
        }
    }
}
