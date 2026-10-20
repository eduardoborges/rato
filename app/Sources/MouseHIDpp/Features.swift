import Foundation

// MARK: - Bateria

struct BatteryState: CustomStringConvertible {
    var percent: Int?
    var status: String       // "descarregando", "carregando", "cheia", "erro de carga"...
    var voltageMv: Int?
    var approx: Bool         // true se % estimada por tensão (0x1001)
    var source: String       // "0x1000" | "0x1001"

    var description: String {
        var head = "bateria[\(source)]"
        if let p = percent { head += " \(approx ? "≈" : "")\(p)%" }
        if let mv = voltageMv { head += " (\(mv)mV)" }
        head += " • \(status)"
        return head
    }
}

// MARK: - Lighting

enum LightingPath: CustomStringConvertible {
    case none
    case e8070(HidppClient.FeatureRef)  // COLOR_LED_EFFECTS (zonal RGB)
    case e8071(HidppClient.FeatureRef)  // RGB_EFFECTS (multi-led)
    case mono1300(HidppClient.FeatureRef) // LED_CONTROL (mono)

    var description: String {
        switch self {
        case .none: return "nenhum"
        case .e8070: return "0x8070 (zonal RGB)"
        case .e8071: return "0x8071 (multi-led RGB)"
        case .mono1300: return "0x1300 (mono)"
        }
    }
}

extension HidppClient {

    /// Lê bateria via 0x1000 (%+status) ou 0x1001 (mV→%). Layouts byte-exatos de NOTES_HIDPP.md.
    func readBattery() throws -> BatteryState {
        if let f = tryFeature(HidppFeature.batteryLevelStatus.rawValue) {
            let resp = try call(featureIndex: f.index, featureId: HidppFeature.batteryLevelStatus.rawValue,
                                funcIdx: 0, params: [], timeoutMs: 400)
            let p = resp.p
            guard p.count >= 3 else { throw HidppError.unexpectedBody(resp.body) }
            let level = p[0] == 0xff ? nil : Int(p[0])
            let statusByte = p[2]
            let st: String
            switch statusByte {
            case 0: st = "descarregando"
            case 1: st = "carregando"
            case 2: st = "quase completa"
            case 3: st = "cheia"
            case 4: st = "erro de carga"
            default: st = String(format: "status 0x%02x", statusByte)
            }
            return BatteryState(percent: level, status: st, voltageMv: nil, approx: false, source: "0x1000")
        }

        if let f = tryFeature(HidppFeature.batteryVoltage.rawValue) {
            let resp = try call(featureIndex: f.index, featureId: HidppFeature.batteryVoltage.rawValue,
                                funcIdx: 0, params: [], timeoutMs: 400)
            let p = resp.p
            guard p.count >= 3 else { throw HidppError.unexpectedBody(resp.body) }
            let mv = (Int(p[0]) << 8) | Int(p[1])
            let flags = p[2]
            let charging = flags & 0x80 != 0
            let fault = Int(flags & 0x07)
            let st = charging ? "carregando" : (fault != 0 ? "fault 0x\(String(fault, radix: 16))" : "descarregando")
            // Estimativa linear (Li-ion ~3.4 → 4.12 V); para AA/mV baixos não estimamos.
            var pct: Int? = nil
            if mv > 2200 { pct = max(0, min(100, ((mv - 3400) * 100) / (4120 - 3400))) }
            return BatteryState(percent: pct, status: st, voltageMv: mv, approx: true, source: "0x1001")
        }
        throw HidppError.notSupported("device sem 0x1000/0x1001")
    }

    /// Lista todas as features via FeatureSet (0x0001): f0 dá a quantidade, f1(i) dá [idHi, idLo, tipo, versão].
    /// O índice 0 é o root (0x0000) e fica de fora.
    func listFeatures() throws -> [(index: UInt8, id: UInt16, type: UInt8, version: UInt8)] {
        let fs = try feature(HidppFeature.featureSet.rawValue)
        let count = try call(featureIndex: fs.index, featureId: HidppFeature.featureSet.rawValue, funcIdx: 0, params: []).p.first ?? 0
        return try (1...max(count, 1)).map { i in
            let p = try call(featureIndex: fs.index, featureId: HidppFeature.featureSet.rawValue,
                             funcIdx: 1, params: [i]).p
            return (i, UInt16(p[0]) << 8 | UInt16(p[1]), p[2], p[3])
        }
    }

    /// Qual caminho de lighting esse device expõe.
    func lightingPath() -> LightingPath {
        if let f = tryFeature(HidppFeature.colorLedEffects8070.rawValue) { return .e8070(f) }
        if let f = tryFeature(HidppFeature.rgbEffects8071.rawValue) { return .e8071(f) }
        if let f = tryFeature(HidppFeature.ledControl1300.rawValue) { return .mono1300(f) }
        return .none
    }
}
