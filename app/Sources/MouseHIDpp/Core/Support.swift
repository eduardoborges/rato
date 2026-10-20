import Foundation

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

let backupRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MouseHIDpp/backups")

func newBackupDir() -> URL {
    backupRoot.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
}
