import Foundation

/// Qualquer mouse externo sem driver próprio: mostra o nome e, se for Bluetooth, a bateria.
/// Não abre a interface: o macOS recusa o open das interfaces de mouse de boot, e as propriedades
/// se leem sem ele.
final class GenericDriver: MouseDriver, MouseDriverType {
    static let vendorIDs: Set<Int> = []

    let bridge: HIDDeviceBridge

    init(bridge: HIDDeviceBridge) { self.bridge = bridge }

    var name: String { bridge.productName }
    var connection: String { bridge.transport }
    var key: String { "generic@\(bridge.vidpid)@\(bridge.locationId)" }
    var details: [String] { ["hw        : \(bridge.description)", "driver    : genérico, só bateria Bluetooth"] }

    func readBattery() throws -> BatteryState? {
        let match = BluetoothBattery.connected(isMouse).first {
            ($0.vendorID == bridge.vendorId && $0.productID == bridge.productId) || $0.name == bridge.productName
        }
        guard let p = match?.percent else { return nil }
        return BatteryState(percent: p, status: "", charging: false, voltageMv: nil, approx: false, source: "bluetooth")
    }

    func readSettings() throws -> MouseSettings? { nil }

    func apply(_ change: SettingChange) throws {
        throw UnsupportedSetting(description: "\(name) não tem driver com ajustes")
    }

    static func probe(_ bridge: HIDDeviceBridge) -> [MouseDriver] {
        guard bridge.usagePage == 1, bridge.usage == 2, !bridge.builtIn else { return [] }
        hlog("+ \(bridge.productName) [genérico, \(bridge.transport)]")
        return [GenericDriver(bridge: bridge)]
    }
}

let isMouse: (String) -> Bool = { $0.localizedCaseInsensitiveContains("mouse") }

/// Bateria de aparelhos Bluetooth conectados, lida do `system_profiler`. Fica em cache por 20 s
/// porque cada mouse pergunta a cada atualização.
enum BluetoothBattery {
    struct Device: Equatable {
        var name: String
        var minorType: String
        var vendorID: Int?
        var productID: Int?
        var percent: Int?
    }

    private static let lock = NSLock()
    private static var cache: (at: Date, devices: [Device])?

    static func connected(_ type: (String) -> Bool) -> [Device] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.at) < 20 { return c.devices.filter { type($0.minorType) } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let devices = parse(data)
        cache = (Date(), devices)
        return devices.filter { type($0.minorType) }
    }

    static func parse(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        func hex(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } }
        return controllers.flatMap { ($0["device_connected"] as? [[String: Any]]) ?? [] }
            .flatMap { $0 }
            .compactMap { name, value in
                guard let info = value as? [String: Any] else { return nil }
                let level = (info["device_batteryLevelMain"] ?? info["device_batteryLevel"]) as? String
                return Device(name: name, minorType: info["device_minorType"] as? String ?? "",
                              vendorID: hex(info["device_vendorID"]), productID: hex(info["device_productID"]),
                              percent: level.flatMap { Int($0.replacingOccurrences(of: "%", with: "")) })
            }
    }
}
