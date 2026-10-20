import Foundation
import IOKit
import IOKit.hid

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
        thread.name = "Rato-HIDLoop"
        rlThread = thread
        startedAt = Date()
        thread.start()
    }

    private func setupManagerOnHIDRunLoop() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        // Interfaces dos fabricantes com driver próprio e qualquer mouse (Generic Desktop / Mouse).
        let vendors: [NSDictionary] = Drivers.all.flatMap { $0.vendorIDs }.map { ["VendorID": $0] }
        let mice: NSDictionary = ["PrimaryUsagePage": 1, "PrimaryUsage": 2]
        IOHIDManagerSetDeviceMatchingMultiple(manager, (vendors + [mice]) as CFArray)

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
        lock.lock()
        if !bridges.contains(where: { $0.device === device }) { bridges.append(bridge) }
        pendingScans += 1
        lock.unlock()
        scanAsync(bridge)
    }

    /// Quem chama já incrementou pendingScans.
    private func scanAsync(_ bridge: HIDDeviceBridge) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for driver in Drivers.route(vendorID: bridge.vendorId)?.probe(bridge) ?? [] {
                self.addTarget(MouseTarget(driver: driver, bridge: bridge))
            }
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

    /// Lê bateria e ajustes antes de mostrar. Uma mesma `key` só entra uma vez.
    private func addTarget(_ t: MouseTarget) {
        t.refreshBattery()
        t.refreshSettings()
        lock.lock()
        if !targets.contains(where: { $0.driver.key == t.driver.key }) { targets.append(t) }
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
                if profiles { t.refreshSettings() }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.notify() }
    }

    /// Grava uma mudança no mouse fora da main thread e relê os ajustes.
    func apply(_ change: SettingChange, to t: MouseTarget) {
        t.busy = true
        notify()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try t.driver.apply(change)
                t.setLastAction(nil)
            } catch {
                t.setLastAction("Não gravou: \(error)")
                hlog("\(t.label): \(error)")
            }
            t.refreshSettings()
            t.refreshBattery() // a previsão de duração depende do polling e do LED
            t.busy = false
            self.notify()
        }
    }
}
