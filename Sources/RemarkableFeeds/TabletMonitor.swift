import Foundation
import Network

/// Figyeli, hogy a tablet USB web interface-e elérhető-e, és csatlakozáskor jelez.
///
/// Az USB-kábel egy új hálózati interfészként jelenik meg, erre azonnal ellenőrzünk; emellett
/// rendszeresen is, mert a web interface a tablet feloldásakor vagy bekapcsolásakor is elérhetővé válhat.
@MainActor
final class TabletMonitor: ObservableObject {
    @Published private(set) var isConnected = false

    /// Minden sikeres ellenőrzéskor hívódik; a paraméter jelzi, hogy most csatlakozott-e.
    /// (A napi szinkron akkor is elindulhat, ha a tablet már korábban be volt dugva.)
    var onAvailable: ((_ newlyConnected: Bool) -> Void)?

    private let usb = RemarkableUSB()
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var isChecking = false
    /// Szinkronizálás közben a tablet lassabban válaszolhat; egyetlen kihagyás miatt még nem
    /// tekintjük leválasztottnak (különben visszacsatlakozáskor újra elindulna a szinkron).
    private var failures = 0

    func start() {
        guard timer == nil else { return }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        pathMonitor.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        if await usb.isReachable() {
            failures = 0
            let newlyConnected = !isConnected
            isConnected = true
            onAvailable?(newlyConnected)
        } else {
            failures += 1
            if failures >= 2 { isConnected = false }
        }
    }
}
