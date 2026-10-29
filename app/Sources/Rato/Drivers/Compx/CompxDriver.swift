import AppKit

/// Mouse ATK ou VXE com chip Compx, no cabo ou no receptor 2.4 GHz. O receptor repassa os comandos ao mouse.
final class CompxDriver: MouseDriver, MouseDriverType {
    static let vendorIDs: Set<Int> = [0x373B]

    /// Polling em Hz → código gravado na EEPROM.
    static let rates: [Int: UInt8] = [125: 8, 250: 4, 500: 2, 1000: 1, 2000: 16, 4000: 32, 8000: 64]
    static let maxLevels = 8

    let bridge: HIDDeviceBridge
    let client: CompxClient
    let isReceiver: Bool
    private(set) var cid = 0
    private(set) var mid = 0

    init(bridge: HIDDeviceBridge, client: CompxClient, isReceiver: Bool) {
        self.bridge = bridge
        self.client = client
        self.isReceiver = isReceiver
    }

    private var model: (name: String, sensor: CompxSensor)? { Self.models[[cid, mid]] }
    var name: String { model?.name ?? bridge.productName }
    var connection: String { isReceiver ? bridge.productName : bridge.transport }
    var key: String { "compx@\(bridge.locationId)" }
    var details: [String] {
        ["hw        : \(bridge.description)", "modelo    : cid \(cid), mid \(mid), sensor \(model?.sensor.rawValue ?? "?")"]
    }

    /// Só os receptores e mouses de 8 kHz aceitam polling acima de 1000 Hz.
    private var supportedRates: [Int] {
        Self.rates.keys.filter { $0 <= 1000 || bridge.productName.localizedCaseInsensitiveContains("8k") }.sorted()
    }

    /// O ATK HUB fala pelo mesmo report; com ele aberto, gravar no mouse não é seguro.
    static func atkHubRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "cn.atk.drive").isEmpty
    }

    func readBattery() throws -> BatteryState? {
        if isReceiver, !(try client.mouseOnline()) { throw CompxError.mouseOffline }
        let b = try client.battery()
        return BatteryState(percent: b.percent, status: b.charging ? "carregando" : "descarregando", charging: b.charging,
                            voltageMv: b.mv > 0 ? b.mv : nil, approx: false, source: "compx")
    }

    func readSettings() throws -> MouseSettings? {
        let c = try readConfig()
        var levels: [Int] = []
        if let sensor = model?.sensor, sensor.converts { levels = try readLevels(c.count, sensor: sensor) }
        let limits = model?.sensor.limits
        return MouseSettings(
            dpiLevels: levels, defaultDpiIndex: c.current, dpiRange: limits?.range, dpiStep: limits?.step ?? 1,
            maxDpiLevels: Self.maxLevels,
            reportRateHz: Self.rates.first { $0.value == c.raw[0] }?.key ?? 0, supportedRatesHz: supportedRates,
            led: nil, ledKinds: [])
    }

    func apply(_ change: SettingChange) throws {
        guard !Self.atkHubRunning() else { throw CompxError.notSupported("feche o ATK HUB antes de gravar no mouse") }
        if isReceiver, !(try client.mouseOnline()) { throw CompxError.mouseOffline }
        var c = try readConfig()
        switch change {
        case let .dpi(levels, def):
            guard let sensor = model?.sensor, sensor.converts else {
                throw CompxError.notSupported("o Rato ainda não grava o DPI do sensor \(model?.sensor.rawValue ?? "desconhecido")")
            }
            guard (1...Self.maxLevels).contains(levels.count), levels.indices.contains(def) else {
                throw CompxError.notSupported("de 1 a \(Self.maxLevels) níveis, padrão entre 1 e \(levels.count)")
            }
            let (range, step) = sensor.limits
            for v in levels where !sensor.accepts(v) {
                throw CompxError.notSupported("DPI \(v) fora de \(range.lowerBound)...\(range.upperBound) passo \(step)\(sensor.coarseSteps)")
            }
            try writeLevels(levels, sensor: sensor)
            c.set(2, UInt8(levels.count))
            c.set(4, UInt8(def))
        case let .dpiDefault(i):
            guard (0..<c.count).contains(i) else { throw CompxError.notSupported("nível \(i + 1) não existe (há \(c.count))") }
            c.set(4, UInt8(i))
        case let .rate(hz):
            guard let code = Self.rates[hz], supportedRates.contains(hz) else {
                throw CompxError.notSupported("polling \(hz) Hz fora de \(supportedRates) Hz")
            }
            c.set(0, code)
        case .led:
            throw CompxError.notSupported("o Rato ainda não muda a luz deste mouse")
        }
        try client.update(0, c.raw)
        hlog("\(name): gravado")
    }

    // MARK: EEPROM

    /// Endereço 0x0000: polling, quantos níveis de DPI, o nível em uso (base 0) e o bhop, cada um seguido do byte de
    /// conferência.
    private struct Config {
        var raw: [UInt8]
        var count: Int { Int(raw[2]) }
        var current: Int { Int(raw[4]) }
        mutating func set(_ i: Int, _ v: UInt8) {
            raw[i] = v
            raw[i + 1] = CompxClient.fieldCheck([v])
        }
    }

    private func readConfig() throws -> Config {
        let raw = try client.read(0, count: 8)
        // O bhop (6 e 7) só existe em alguns modelos.
        guard [0, 2, 4].allSatisfy({ raw[$0 + 1] == CompxClient.fieldCheck([raw[$0]]) }),
              (1...Self.maxLevels).contains(Int(raw[2])), Int(raw[4]) < Int(raw[2]) else {
            throw CompxError.badField(address: 0, raw)
        }
        return Config(raw: raw)
    }

    /// Lê os níveis como o ATK HUB: dois por leitura de 8 bytes, ou um por leitura de 6 no 3955.
    private func readLevels(_ count: Int, sensor: CompxSensor) throws -> [Int] {
        let size = sensor.slot(0).size + 1
        let perRead = 8 / size
        var levels: [Int] = []
        for first in stride(from: 0, to: count, by: perRead) {
            let address = sensor.slot(first).address
            let block = try client.read(address, count: perRead * size)
            for j in 0..<min(perRead, count - first) {
                let s = Array(block[j * size..<(j + 1) * size])
                guard s.last == CompxClient.fieldCheck(s.dropLast()), let v = sensor.decode(Array(s.dropLast())) else {
                    throw CompxError.badField(address: address, block)
                }
                levels.append(v)
            }
        }
        return levels
    }

    /// Grava só os blocos dos níveis usados. Os níveis de fora ficam como estavam.
    private func writeLevels(_ levels: [Int], sensor: CompxSensor) throws {
        let size = sensor.slot(0).size + 1
        let perRead = 8 / size
        for first in stride(from: 0, to: levels.count, by: perRead) {
            let address = sensor.slot(first).address
            var block = try client.read(address, count: perRead * size)
            for j in 0..<min(perRead, levels.count - first) {
                guard let bytes = sensor.encode(levels[first + j]) else { continue }
                block.replaceSubrange(j * size..<(j + 1) * size, with: bytes + [CompxClient.fieldCheck(bytes)])
            }
            try client.update(address, block)
        }
    }

    // MARK: Descoberta

    /// A collection vendor 0xFF02 com o report 8 de 16 bytes, por onde o protocolo passa.
    private static let signature: [UInt8] = [0x06, 0x02, 0xff, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x08]

    static func probe(_ bridge: HIDDeviceBridge) -> [MouseDriver] {
        guard bridge.usagePage >= 0xFF00, bridge.reportDescriptor.firstRange(of: signature) != nil else {
            hlog("· skip \(bridge.productName) usage 0x\(String(bridge.usagePage, radix: 16))/0x\(String(bridge.usage, radix: 16))")
            return []
        }
        // A interface também declara um report de mouse (0x0B). O filtro impede que ele empurre a resposta para fora da fila.
        bridge.inputReportIDs = [CompxClient.reportID]
        do { try bridge.open() } catch {
            hlog("open falhou: \(bridge) — \(error)")
            return []
        }
        let d = CompxDriver(bridge: bridge, client: CompxClient(bridge: bridge),
                            isReceiver: bridge.productName.localizedCaseInsensitiveContains("dongle"))
        do {
            if d.isReceiver, !(try d.client.mouseOnline()) {
                hlog("· \(bridge.productName): \(CompxError.mouseOffline)")
                return []
            }
            (d.cid, d.mid) = try d.client.cidMid()
        } catch {
            hlog("· sem resposta Compx em: \(bridge) — \(error)")
            for line in bridge.dumpTrace() { print("      | \(line)") }
            return []
        }
        hlog("+ \(d.name) [cid \(d.cid), mid \(d.mid)]")
        return [d]
    }
}
