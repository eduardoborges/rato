import AppKit

/// Mouse Logitech com HID++ 2.0: ligado direto (USB/BT) ou num slot de receptor LIGHTSPEED/Unifying.
final class LogitechDriver: MouseDriver, MouseDriverType {
    static let vendorIDs: Set<Int> = [0x046D]

    let bridge: HIDDeviceBridge
    let client: HidppClient
    let isReceiverSlot: Bool
    private(set) var lighting: LightingPath = .none

    // Lidos uma vez: não mudam com o perfil.
    private var dpi: HidppClient.DpiInfo?
    private var rates: [Int] = []
    private var ledKinds: [LedKind]?
    /// Polling e LED do perfil ativo, para a previsão da bateria. Atualizado a cada leitura de ajustes.
    private var profile: HidppClient.OnboardProfile?
    /// nil se o G HUB não deixou um battery.xml para este mouse.
    private lazy var powerModel: PowerModel? = {
        let pids = Result { try client.modelPids() }
        let m = (try? pids.get()).flatMap(PowerModel.load(pids:))
        if m == nil { hlog("\(name): sem modelo de bateria do G HUB (PIDs: \(pids.map { $0.map { String(format: "0x%04x", $0) } }))") }
        return m
    }()

    init(bridge: HIDDeviceBridge, client: HidppClient, isReceiverSlot: Bool) {
        self.bridge = bridge
        self.client = client
        self.isReceiverSlot = isReceiverSlot
    }

    var name: String {
        if isReceiverSlot { return "\(bridge.productName) (slot \(client.deviceIndex))" }
        return bridge.productName + (bridge.transport.uppercased().contains("BLUE") ? " (BT)" : " (direct)")
    }

    var key: String { "logitech@\(bridge.locationId)#\(client.deviceIndex)" }

    var details: [String] { ["hw        : \(bridge.description)", "lighting  : \(lighting.description)"] }

    /// O lghub_agent usa o mesmo canal HID++; com ele aberto, gravar no mouse não é seguro.
    static func gHubAgentRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.logi.ghub.agent").isEmpty
    }

    func readBattery() throws -> BatteryState? {
        var b: BatteryState
        do { b = try client.readBattery() } catch HidppError.notSupported { return nil }
        // Com o modelo do G HUB, a % sai da curva de descarga em vez da reta 3,4 → 4,12 V.
        guard !b.charging, let mv = b.voltageMv, let m = powerModel else { return b }
        let left = m.capacityMwh - m.usedMwh(volts: Double(mv) / 1000)
        b.percent = Int((left / m.capacityMwh * 100).rounded())
        if let p = profile ?? (try? client.activeProfile()) {
            profile = p
            b.hoursLeft = left / m.powerMw(rateMs: p.reportRateMs, leds: p.leds.compactMap(LedEffect.init(hidppProfileBytes:)))
        }
        return b
    }

    func readSettings() throws -> MouseSettings? {
        guard client.tryFeature(HidppFeature.onboardProfiles.rawValue) != nil else { return nil }
        let p = try client.activeProfile()
        profile = p
        if dpi == nil { dpi = try client.dpiInfo() }
        if rates.isEmpty { rates = try client.reportRates().supported }
        if ledKinds == nil {
            let ids = (try? client.ledClusters().first?.effects) ?? []
            let map: [UInt16: LedKind] = [0x00: .off, 0x01: .fixed, 0x03: .cycle, 0x0a: .breathe]
            ledKinds = ids.compactMap { map[$0] }
        }
        guard let dpi else { return nil }
        return MouseSettings(
            dpiLevels: p.dpis.filter { $0 > 0 }, defaultDpiIndex: p.defaultDpiIndex,
            dpiRange: dpi.min...dpi.max, dpiStep: dpi.step ?? 1,
            reportRateMs: p.reportRateMs, supportedRatesMs: rates,
            led: LedEffect(hidppProfileBytes: p.leds[0]), ledKinds: ledKinds ?? [])
    }

    func apply(_ change: SettingChange) throws {
        guard !Self.gHubAgentRunning() else {
            throw HidppError.notSupported("feche o G HUB antes de gravar no mouse (lghub_agent rodando)")
        }
        hlog("\(name): gravado (backup em \(try client.apply(change).path))")
    }

    // MARK: Descoberta

    /// Tem bateria ou LED? A descoberta às vezes falha no primeiro "wake" da interface, por isso repete.
    private func probeCapabilities() -> Bool {
        for _ in 0..<2 {
            lighting = client.lightingPath()
            if case .none = lighting {} else { return true }
            if (try? readBattery()) != nil { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    static func probe(_ bridge: HIDDeviceBridge) -> [MouseDriver] {
        // HID++ mora na collection vendor (usage page 0xFF00, reports de 32 B). As interfaces de
        // teclado e mouse de boot (usage page 1) não falam HID++ e o macOS recusa o open.
        let vendor = bridge.usagePage == 0xFF00 || (bridge.usagePage >= 0xFF00 && bridge.maxIn >= 20 && bridge.maxOut >= 7)
        guard vendor else {
            hlog("· skip \(bridge.productName) usage 0x\(String(bridge.usagePage, radix: 16))/0x\(String(bridge.usage, radix: 16))")
            return []
        }
        do { try bridge.open() } catch {
            hlog("open falhou: \(bridge) — \(error)")
            return []
        }
        // settle: deixa a interface acordar antes do primeiro request
        Thread.sleep(forTimeInterval: 0.3)
        _ = bridge.drainInputBodies()

        // 1) conexão direta (USB/BT) usa deviceIndex 0xFF
        let direct = HidppClient(bridge: bridge, deviceIndex: 0xff, devLabel: bridge.productName)
        if direct.probeHandshake(timeoutMs: 250) {
            hlog("· \(bridge.desc): HID++ ok [\(direct.transport.rawValue)/\(direct.idMode.rawValue)] hs=[\(direct.lastHandshake ?? "-")]")
            let d = LogitechDriver(bridge: bridge, client: direct, isReceiverSlot: false)
            if d.probeCapabilities() {
                hlog("+ \(d.name)")
                return [d]
            }
        }

        // 2) sem nada no 0xFF: é receptor. devIdx 0xFF é o próprio receptor; o mouse pareado está num slot 1...6.
        for slot: UInt8 in 1...6 {
            let c = HidppClient(bridge: bridge, deviceIndex: slot, devLabel: "\(bridge.productName)#s\(slot)")
            guard c.probeHandshake(timeoutMs: 250) else { continue }
            let d = LogitechDriver(bridge: bridge, client: c, isReceiverSlot: true)
            if d.probeCapabilities() {
                hlog("+ \(d.name) [slot \(slot)]")
                return [d]
            }
        }

        hlog("· sem HID++ em: \(bridge)")
        for line in bridge.dumpTrace() { print("      | \(line)") }
        return []
    }
}
