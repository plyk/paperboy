import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var rootPassword = ""
    @State private var isInstallingKey = false
    @State private var keyResult: String?
    @State private var hasSSHKey = (try? SSHKeys.prepare().hasKey) ?? false

    var body: some View {
        Form {
            Section("reMarkable") {
                Picker("Feltöltés módja", selection: $store.settings.transport) {
                    Text("USB web interface").tag(TransportKind.usbWeb)
                    Text("SSH").tag(TransportKind.ssh)
                }
                .pickerStyle(.segmented)
                Text(store.settings.transport == .usbWeb
                     ? "Egyszerű, jelszó nélküli mód USB-kábelen. A tableten be kell kapcsolni a Beállítások → Tárhely → USB web interface opciót."
                     : "Közvetlen hozzáférés root jelszóval: a célmappát a Paperboy hozza létre, a dokumentumnevek .pdf nélkül jelennek meg, és Wi-Fi-n is működhet. Feltöltés után a tablet felülete pár másodpercre újraindul.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("A tablet címe", text: $store.settings.tabletHost, prompt: Text(RemarkableUSB.defaultHost))
                    if store.settings.tabletHost != RemarkableUSB.defaultHost {
                        Button("Alapérték") { store.settings.tabletHost = RemarkableUSB.defaultHost }
                    }
                }
                Text("USB-kábelen a tablet címe mindig \(RemarkableUSB.defaultHost). SSH-n Wi-Fi-n keresztül a tablet hálózati címét add meg (a tablet Névjegy oldalán látható).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Célmappa", text: $store.settings.targetFolder, prompt: Text("pl. Hírek"))
                Text(store.settings.transport == .usbWeb
                     ? "A mappának léteznie kell a tableten, mert az USB-felületen keresztül nem lehet mappát létrehozni. Almappa: Hírek/Reggeli. Üresen hagyva a gyökérbe kerül."
                     : "Ha még nincs ilyen mappa, a Paperboy létrehozza. Almappa: Hírek/Reggeli. Üresen hagyva a gyökérbe kerül.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Kapcsolat tesztelése") { Task { await test() } }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.callout) }
                }
            }

            if store.settings.transport == .ssh {
                Section("SSH-hozzáférés") {
                    LabeledContent("Paperboy-kulcs", value: hasSSHKey ? "létrehozva" : "még nincs")
                    SecureField("Root jelszó", text: $rootPassword, prompt: Text("a tablet Névjegy oldaláról"))
                    HStack {
                        Button("Kulcs telepítése a tabletre") { Task { await installKey() } }
                            .disabled(rootPassword.isEmpty || isInstallingKey)
                        if isInstallingKey { ProgressView().controlSize(.small) }
                        if let keyResult { Text(keyResult).font(.callout) }
                    }
                    Text("A jelszót a tableten a Beállítások → Általános → Súgó → Névjegy → Szerzői jogok és licencek oldalon, a GPLv3 Compliance résznél találod. Csak egyszer kell: a Paperboy a saját kulcsát telepíti vele, a jelszót nem tárolja. Paper Pro esetén az SSH-hoz fejlesztői mód kell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(isOn: $store.settings.trashOldEditions) {
                        Text("Régi kiadások áthelyezése a Kukába")
                        Text("Csak a Paperboy által létrehozott, jegyzet nélküli kiadásokat érinti; a Kukából visszaállíthatók.")
                    }
                    if store.settings.trashOldEditions {
                        Stepper("\(store.settings.keepEditionsDays) napnál régebbiek",
                                value: $store.settings.keepEditionsDays, in: 1...60)
                    }
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

            Section {
                HStack(spacing: 8) {
                    Image(nsImage: PaperboyLogo.image(height: 18))
                    Text(Self.versionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    /// A build script a git-címkéből írja be a verziót; `swift run`-nál nincs Info.plist.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Paperboy – fejlesztői változat" }
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Paperboy \(version) (build \(build))"
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
        let transport = store.settings.makeTransport()
        do {
            guard await transport.isReachable() else { throw transport.unreachableError }
            testResult = try await transport.test(folder: store.settings.targetFolder)
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func installKey() async {
        isInstallingKey = true
        defer { isInstallingKey = false }
        keyResult = nil
        do {
            try await RemarkableSSH.installKey(host: store.settings.tabletHost, password: rootPassword)
            rootPassword = ""
            keyResult = "✓ Kulcs telepítve, a jelszóra többé nincs szükség."
        } catch {
            keyResult = error.localizedDescription
        }
        hasSSHKey = (try? SSHKeys.prepare().hasKey) ?? false
    }
}
