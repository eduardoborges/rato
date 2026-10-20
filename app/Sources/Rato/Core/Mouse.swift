import Foundation

// Modelo comum a todos os drivers. A UI e a linha de comando só conhecem estes tipos.

struct BatteryState: CustomStringConvertible {
    var percent: Int?
    var status: String       // texto livre do driver: "descarregando", "carregando", "cheia"...
    var charging: Bool
    var voltageMv: Int?
    var approx: Bool         // true se a % é estimada pela tensão
    var source: String       // de onde veio: "0x1001", "bluetooth"...
    var hoursLeft: Double? = nil  // em uso contínuo, se o driver souber estimar

    /// "~24 h de uso", "~40 min de uso".
    var timeLeftText: String? {
        hoursLeft.map { $0 < 1 ? "~\(Int($0 * 60)) min de uso" : "~\(Int($0.rounded())) h de uso" }
    }

    var description: String {
        var head = "bateria[\(source)]"
        if let p = percent { head += " \(approx ? "≈" : "")\(p)%" }
        if let mv = voltageMv { head += " (\(mv)mV)" }
        if !status.isEmpty { head += " • \(status)" }
        if let t = timeLeftText { head += " • \(t)" }
        return head
    }
}

enum LedEffect: Equatable {
    case off
    case fixed(UInt8, UInt8, UInt8)
    case breathe(UInt8, UInt8, UInt8, periodMs: Int, intensity: Int)
    case cycle(periodMs: Int, intensity: Int)
}

enum LedKind: CaseIterable {
    case off, fixed, breathe, cycle
}

/// O que o mouse aceita e o que está gravado nele. Lista vazia = o mouse não tem aquele ajuste.
struct MouseSettings {
    var dpiLevels: [Int]
    var defaultDpiIndex: Int
    var dpiRange: ClosedRange<Int>?
    var dpiStep: Int
    var reportRateMs: Int
    var supportedRatesMs: [Int]
    var led: LedEffect?
    var ledKinds: [LedKind]
}

enum SettingChange {
    case dpi(levels: [Int], defaultIndex: Int)
    case dpiDefault(Int)
    case rate(ms: Int)
    case led(LedEffect)
}

/// Um mouse encontrado por um driver.
protocol MouseDriver: AnyObject {
    var name: String { get }
    /// Identifica o mouse entre interfaces HID repetidas do mesmo aparelho.
    var key: String { get }
    var details: [String] { get }
    /// nil = o mouse não informa bateria.
    func readBattery() throws -> BatteryState?
    /// nil = o driver só lê, sem ajustes.
    func readSettings() throws -> MouseSettings?
    func apply(_ change: SettingChange) throws
}

/// Cada tipo de driver diz de quais fabricantes cuida e acha os mouses numa interface HID.
protocol MouseDriverType {
    /// Vazio = genérico, usado quando nenhum outro driver reivindica o fabricante.
    static var vendorIDs: Set<Int> { get }
    static func probe(_ bridge: HIDDeviceBridge) -> [MouseDriver]
}

enum Drivers {
    static func route(vendorID: Int, in types: [MouseDriverType.Type] = all) -> MouseDriverType.Type? {
        types.first { $0.vendorIDs.contains(vendorID) } ?? types.first { $0.vendorIDs.isEmpty }
    }
}

struct UnsupportedSetting: Error, CustomStringConvertible {
    let description: String
}

/// Um mouse na UI: o driver e o último estado lido dele.
final class MouseTarget: @unchecked Sendable {
    let driver: MouseDriver
    let bridge: HIDDeviceBridge

    private let stateLock = NSLock()
    private var _battery: BatteryState?
    private var _batteryErr: String?
    private var _batteryAt: Date?
    private var _settings: MouseSettings?
    private var _lastAction: String?
    private var _busy = false

    init(driver: MouseDriver, bridge: HIDDeviceBridge) {
        self.driver = driver
        self.bridge = bridge
    }

    var label: String { driver.name }
    var battery: BatteryState? { stateLock.lock(); defer { stateLock.unlock() }; return _battery }
    var batteryErr: String? { stateLock.lock(); defer { stateLock.unlock() }; return _batteryErr }
    var batteryAt: Date? { stateLock.lock(); defer { stateLock.unlock() }; return _batteryAt }
    var settings: MouseSettings? { stateLock.lock(); defer { stateLock.unlock() }; return _settings }
    var lastAction: String? { stateLock.lock(); defer { stateLock.unlock() }; return _lastAction }
    var busy: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _busy }
        set { stateLock.lock(); _busy = newValue; stateLock.unlock() }
    }

    func setLastAction(_ s: String?) {
        stateLock.lock(); _lastAction = s; stateLock.unlock()
    }

    func refreshBattery() {
        let result = Result { try driver.readBattery() }
        stateLock.lock()
        switch result {
        case .success(let b): _battery = b; _batteryErr = nil; _batteryAt = Date()
        // Guarda a última leitura: um mouse dormindo não responde, e o menu mostra o valor antigo com a hora da leitura.
        case .failure(let e): _batteryErr = String(describing: e)
        }
        stateLock.unlock()
    }

    func refreshSettings() {
        guard let s = try? driver.readSettings() else { return }
        stateLock.lock(); _settings = s; stateLock.unlock()
    }
}
