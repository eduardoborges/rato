import Foundation

// MARK: - HID++ constants

/// HID++ feature IDs used by lghub_agent (byte-exact from analysis/NOTES_HIDPP.md)
enum HidppFeature: UInt16 {
    case root = 0x0000
    case featureSet = 0x0001
    case deviceInfo = 0x0003
    case deviceName = 0x0005
    case batteryLevelStatus = 0x1000
    case batteryVoltage = 0x1001
    case ledControl1300 = 0x1300
    case colorLedEffects8070 = 0x8070
    case rgbEffects8071 = 0x8071
    case adjustableDpi = 0x2201
    case reportRate = 0x8060
    case onboardProfiles = 0x8100
}

enum HidppError: Error, CustomStringConvertible {
    case noResponse(function: Int, feature: UInt16)
    case deviceError(code: UInt8, feature: UInt16, function: Int) // body[1]==0, body[2]==0, code em body[3]
    case deviceError20(code: UInt8, feature: UInt16, function: Int)
    case unexpectedBody([UInt8])
    case notSupported(String)

    var description: String {
        switch self {
        case .noResponse(let f, let feat): return "sem resposta (feature \(fmtByte(UInt8(feat >> 8)))\(fmtByte(UInt8(feat & 0xff))) f\(f))"
        case .deviceError(let code, let feat, let f):
            let names: [UInt8: String] = [
                0x01: "feature desconhecida no device",
                0x02: "parâmetro inválido",
                0x03: "valor inválido",
                0x04: "busy",
                0x05: "argumento insuficiente",
                0x06: "sem sync",
            ]
            return "device err \(code) (\(names[code] ?? "?")) feature \(feat) f\(f)"
        case .deviceError20(let code, let feat, let f):
            let names = ["sem erro", "desconhecido", "argumento inválido", "fora da faixa", "erro de hardware",
                         "não permitido", "índice de feature inválido", "função inválida", "ocupado", "não suportado"]
            return String(format: "erro HID++ 2.0 %u (%@) feature 0x%04x f%d",
                          code, code < names.count ? names[Int(code)] : "?", feat, f)
        case .unexpectedBody(let b): return "resposta inesperada: \(hex(b))"
        case .notSupported(let w): return w
        }
    }

    var isNoResponse: Bool { if case .noResponse = self { return true }; return false }
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
            return BatteryState(percent: level, status: st, charging: statusByte == 1, voltageMv: nil, approx: false, source: "0x1000")
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
            // Curva genérica de Li-ion; para pilha AA (mV baixos) não estimamos.
            let pct = mv > 2200 ? Int(BatteryModel.priorPercent(mv).rounded()) : nil
            return BatteryState(percent: pct, status: st, charging: charging, voltageMv: mv, approx: true, source: "0x1001")
        }
        throw HidppError.notSupported("device sem 0x1000/0x1001")
    }

    /// PIDs do mouse em cada transporte: 0x0003 f0 traz o modelId (3 PIDs de 2 bytes) a partir do byte 7.
    func modelPids() throws -> [Int] {
        let f = try feature(HidppFeature.deviceInfo.rawValue)
        let p = try call(featureIndex: f.index, featureId: HidppFeature.deviceInfo.rawValue, funcIdx: 0, params: []).p
        guard p.count >= 13 else { throw HidppError.unexpectedBody(p) }
        return stride(from: 7, to: 13, by: 2).map { Int(p[$0]) << 8 | Int(p[$0 + 1]) }.filter { $0 != 0 }
    }

    /// Nome que o mouse informa (0x0005): f0 dá o tamanho, f1(i) devolve os caracteres a partir do i.
    func deviceName() throws -> String {
        let id = HidppFeature.deviceName.rawValue
        let f = try feature(id)
        let count = Int(try call(featureIndex: f.index, featureId: id, funcIdx: 0, params: []).p.first ?? 0)
        var bytes: [UInt8] = []
        while bytes.count < count {
            let p = try call(featureIndex: f.index, featureId: id, funcIdx: 1, params: [UInt8(bytes.count)]).p
            guard !p.isEmpty else { break }
            bytes += p.prefix(count - bytes.count)
        }
        return String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
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
