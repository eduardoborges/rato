import AppKit

// MARK: - Small utilities

func hlog(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

func hex(_ data: [UInt8], cap: Int = 48) -> String {
    let body = data.prefix(cap).map { String(format: "%02x", $0) }.joined(separator: " ")
    return data.count > cap ? body + " …(\(data.count))" : body
}

func fmtByte(_ b: UInt8) -> String { String(format: "0x%02x", b) }

/// O lghub_agent usa o mesmo canal HID++; com ele aberto, gravar no mouse não é seguro.
func gHubAgentRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.logi.ghub.agent").isEmpty
}

let backupRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MouseHIDpp/backups")

func newBackupDir() -> URL {
    backupRoot.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
}

// MARK: - HID++ constants

/// HID++ feature IDs used by lghub_agent (byte-exact from analysis/NOTES_HIDPP.md)
enum HidppFeature: UInt16 {
    case root = 0x0000
    case featureSet = 0x0001
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
