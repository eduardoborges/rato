import Foundation
import IOKit
import IOKit.hid

/// Um "alvo" = uma instância de mouse (conexão direta OU um slot de receptor).
final class MouseTarget: @unchecked Sendable {
    let bridge: HIDDeviceBridge
    let client: HidppClient
    let isReceiverSlot: Bool
    private let devLabel: String

    private let stateLock = NSLock()
    private var _battery: BatteryState?
    private var _batteryErr: String?
    private var _lighting: LightingPath = .none
    private var _lastAction: String?
    private var _profile: HidppClient.OnboardProfile?
    private var _busy = false
    /// Taxas de polling aceitas (ms), lidas uma vez.
    private(set) var reportRates: [Int] = []

    init(bridge: HIDDeviceBridge, client: HidppClient, isReceiverSlot: Bool, label: String) {
        self.bridge = bridge
        self.client = client
        self.isReceiverSlot = isReceiverSlot
        self.devLabel = label
    }

    var label: String {
        var base = bridge.productName
        if isReceiverSlot { base += " (slot \(client.deviceIndex))" }
        else if bridge.transport.uppercased().contains("BLUE") { base += " (BT)" }
        else { base += " (direct)" }
        return base
    }

    var battery: BatteryState? { stateLock.lock(); defer { stateLock.unlock() }; return _battery }
    var batteryErr: String? { stateLock.lock(); defer { stateLock.unlock() }; return _batteryErr }
    var lighting: LightingPath { stateLock.lock(); defer { stateLock.unlock() }; return _lighting }
    var lastAction: String? { stateLock.lock(); defer { stateLock.unlock() }; return _lastAction }

    var profile: HidppClient.OnboardProfile? { stateLock.lock(); defer { stateLock.unlock() }; return _profile }
    var busy: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _busy }
        set { stateLock.lock(); _busy = newValue; stateLock.unlock() }
    }

    func setLastAction(_ s: String?) {
        stateLock.lock(); _lastAction = s; stateLock.unlock()
    }

    func refreshProfile() {
        guard let p = try? client.activeProfile() else { return }
        if reportRates.isEmpty { reportRates = (try? client.reportRates().supported) ?? [] }
        stateLock.lock(); _profile = p; stateLock.unlock()
    }

    private func setLighting(_ p: LightingPath) {
        stateLock.lock(); _lighting = p; stateLock.unlock()
    }
    private func setBattery(_ b: BatteryState?, err: String?) {
        stateLock.lock(); _battery = b; _batteryErr = err; stateLock.unlock()
    }

    /// Sonda capabilities do device. Retorna true se tiver bateria OU lighting.
    /// Com repetição — a descoberta às vezes dá tapa no "wake" da interface.
    @discardableResult
    func probeCapabilities() -> Bool {
        for _ in 0..<2 {
            let lp = client.lightingPath()
            setLighting(lp)
            if case .none = lp {} else { refreshBattery(); refreshProfile(); return true }
            refreshBattery()
            if _battery != nil { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    func refreshBattery() {
        do {
            let st = try client.readBattery()
            setBattery(st, err: nil)
        } catch {
            if case HidppError.notSupported = error {
                setBattery(nil, err: nil)
            } else {
                setBattery(nil, err: String(describing: error))
            }
        }
    }
}

// MARK: - Engine

/// Thread dedicada com CFRunLoop: callbacks de matching/removal/input do IOKit moram aqui.
final class HIDRunLoopThread: Thread, @unchecked Sendable {
    private let work: () -> Void
    init(work: @escaping () -> Void) {
        self.work = work
        super.init()
        qualityOfService = .userInitiated
    }
    override func main() {
        work()
        while true {
            CFRunLoopRunInMode(CFRunLoopMode(rawValue: "kCFRunLoopDefaultMode" as CFString), 60.0, false)
        }
    }
}

final class DeviceEngine: @unchecked Sendable {
    static let shared = DeviceEngine()

    private var manager: IOHIDManager?
    private var rlThread: HIDRunLoopThread?
    private var started = false
    private let lock = NSLock()
    private var targets: [MouseTarget] = []
    /// nº de scans de device em andamento (para o CLI saber quando terminou)
    private var pendingScans = 0
    /// bridges descobertos (para ferramentas de debug de transporte)
    private var bridges: [HIDDeviceBridge] = []

    /// Chamado na main queue quando algo muda (para a UI re-renderizar).
    var onChanged: (@Sendable () -> Void)?

    // MARK: Ciclo

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        let thread = HIDRunLoopThread { [weak self] in self?.setupManagerOnHIDRunLoop() }
        thread.name = "MouseHIDpp-HIDLoop"
        rlThread = thread
        startedAt = Date()
        thread.start()
    }

    private func setupManagerOnHIDRunLoop() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        let matching: NSDictionary = ["VendorID": 0x046D] // Logitech
        IOHIDManagerSetDeviceMatching(manager, matching)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _result, _sender, device in
            guard let ctx = ctx else { return }
            let engine = Unmanaged<DeviceEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.deviceArrived(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _result, _sender, device in
            guard let ctx = ctx else { return }
            let engine = Unmanaged<DeviceEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.deviceRemoved(device)
        }, ctx)

        // Gerência (matching/removal/input) toda nesta runloop dedicada.
        guard let rl = CFRunLoopGetCurrent() else { return }
        IOHIDManagerScheduleWithRunLoop(manager, rl, "kCFRunLoopDefaultMode" as CFString)
        IOHIDManagerOpen(manager, 0)
    }

    /// Espera os scans pendentes. O budget é teto; sai antes quando a fila zera.
    @discardableResult
    func scan(waitSeconds: Double) -> Int {
        start()
        let deadline = Date().addingTimeInterval(waitSeconds)
        // a thread HID precisa de um instante para o matching disparar
        Thread.sleep(forTimeInterval: 0.35)
        while Date() < deadline {
            lock.lock()
            let pending = pendingScans
            let seen = bridges.count
            lock.unlock()
            if pending == 0 && seen > 0 && Date().timeIntervalSince(startedAt) > 0.8 {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock()
                let still = pendingScans
                lock.unlock()
                if still == 0 { break }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return snapshot().count
    }

    private var lastTargetCount = -1
    private var startedAt = Date()

    func snapshot() -> [MouseTarget] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    // MARK: Enumeração

    private func deviceArrived(_ device: IOHIDDevice) {
        // fires na runloop HID — a runloop atual é a privada do IOKit
        guard let rl = CFRunLoopGetCurrent() else { return }
        let bridge = HIDDeviceBridge(device: device, runLoop: rl)
        guard bridge.vendorId == 0x046D else { return } // Logitech
        // HID++ mora na collection vendor (0xFF00). Teclado/mouse boot (usage page 1)
        // devolve kIOReturnNotPermitted e não fala HID++.
        guard bridge.usagePage >= 0xFF00 else {
            hlog("· skip boot \(bridge.productName) usage 0x\(String(bridge.usagePage, radix: 16))/0x\(String(bridge.usage, radix: 16))")
            return
        }

        lock.lock()
        if !bridges.contains(where: { $0.device === device }) { bridges.append(bridge) }
        pendingScans += 1
        lock.unlock()
        scanAsync(bridge)
    }

    /// Quem chama já incrementou pendingScans.
    private func scanAsync(_ bridge: HIDDeviceBridge) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanBridge(bridge)
            guard let self = self else { return }
            self.lock.lock(); self.pendingScans -= 1; self.lock.unlock()
            self.notify()
        }
    }

    /// Sonda de novo os bridges sem alvo, como o de um mouse que dormia na abertura e não respondeu ao handshake.
    func rescan() {
        lock.lock()
        let orphans = pendingScans > 0 ? [] : bridges.filter { b in !targets.contains { $0.bridge === b } }
        pendingScans += orphans.count
        lock.unlock()
        orphans.forEach(scanAsync)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        lock.lock()
        targets.removeAll { $0.bridge.device == device }
        bridges.removeAll { $0.device == device }
        lock.unlock()
        notify()
    }

    private func scanBridge(_ bridge: HIDDeviceBridge) {
        // HID++ no C539 mora na interface vendor (usage page 0xFF00, reports de 32B).
        // Teclado/mouse de boot (usage 0x01) não falam HID++ e o macOS recusa o open.
        let vendor = bridge.usagePage == 0xFF00 || (bridge.maxIn >= 20 && bridge.maxOut >= 7)
        guard vendor else {
            hlog("· skip \(bridge.productName) usage 0x\(String(bridge.usagePage, radix: 16))/0x\(String(bridge.usage, radix: 16)) in=\(bridge.maxIn)")
            return
        }
        do { try bridge.open() } catch {
            hlog("open falhou: \(bridge) — \(error)")
            return
        }
        // settle: deixa a interface acordar antes do primeiro request
        Thread.sleep(forTimeInterval: 0.3)
        _ = bridge.drainInputBodies()

        // 1) conexão direta (USB/BT) usa deviceIndex 0xFF — vota transporte × modo de id
        let direct = HidppClient(bridge:bridge, deviceIndex: 0xff, devLabel: bridge.productName)
        var adopted: [MouseTarget] = []
        if direct.probeHandshake(timeoutMs: 250) {
            hlog("· \(bridge.desc): HID++ ok [\(direct.transport.rawValue)/\(direct.idMode.rawValue)] hs=[\(direct.lastHandshake ?? "-")]")
            let t = MouseTarget(bridge: bridge, client: direct, isReceiverSlot: false, label: bridge.productName)
            if t.probeCapabilities() {
                hlog("+ \(t.label)")
                adopted.append(t)
            }
        }

        // 2) sem caps no 0xFF → provável receptor: sonda slots 1..6
        if adopted.isEmpty {
            for slot: UInt8 in 1...6 {
                let c = HidppClient(bridge: bridge, deviceIndex: slot,
                                    devLabel: "\(bridge.productName)#s\(slot)")
                guard c.probeHandshake(timeoutMs: 250) else { continue }
                let t = MouseTarget(bridge: bridge, client: c, isReceiverSlot: true, label: bridge.productName)
                if t.probeCapabilities() {
                    hlog("+ \(t.label) [slot \(slot)]")
                    adopted.append(t)
                }
            }
        }

        // devIdx 0xFF no C539 é o receptor. O mouse pareado é o slot (1..6).
        // O "upgrade" antigo para 0xFF vinha do eco deslocado (report id comia o device index).
        let selection: [MouseTarget]
        if let directT = adopted.first(where: { !$0.isReceiverSlot }) {
            selection = [directT]
        } else if !adopted.isEmpty {
            selection = [adopted[0]]
        } else {
            selection = []
        }
        for t in selection {
            addTarget(t)
        }
        if adopted.count > 1 {
            hlog("! \(bridge.productName): descartados \(adopted.count - 1) alias(es) duplicado(s) do mesmo device")
        }

        if adopted.isEmpty {
            hlog("· sem HID++ em: \(bridge)")
            for line in bridge.dumpTrace() { print("      | \(line)") }
        }
    }

    private func addTarget(_ t: MouseTarget) {
        lock.lock()
        if !targets.contains(where: { $0 === t }) { targets.append(t) }
        lock.unlock()
        notify()
    }

    private func notify() {
        guard let cb = onChanged else { return }
        DispatchQueue.main.async(execute: cb)
    }

    // MARK: Ações

    func refreshAllBatteries(profiles: Bool = false) {
        let targets = snapshot()
        let group = DispatchGroup()
        for t in targets {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                t.refreshBattery()
                if profiles { t.refreshProfile() }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.notify() }
    }

    /// Grava uma mudança no perfil do mouse fora da main thread e relê o perfil.
    func apply(_ change: HidppClient.ProfileChange, to t: MouseTarget) {
        guard !gHubAgentRunning() else {
            t.setLastAction("Feche o G HUB antes de mudar o mouse")
            notify()
            return
        }
        t.busy = true
        notify()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try t.client.apply(change)
                t.setLastAction(nil)
            } catch {
                t.setLastAction("Não gravou: \(error)")
                hlog("\(t.label): \(error)")
            }
            t.refreshProfile()
            t.busy = false
            self.notify()
        }
    }
}
