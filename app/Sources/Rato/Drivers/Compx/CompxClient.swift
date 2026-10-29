import Foundation
import IOKit.hid

enum CompxError: Error, CustomStringConvertible {
    case noResponse(command: UInt8)
    case mouseOffline
    case badField(address: Int, [UInt8])
    case writeMismatch(address: Int)
    case notSupported(String)

    var description: String {
        switch self {
        case .noResponse(let c): return String(format: "sem resposta ao comando 0x%02x", c)
        case .mouseOffline: return "o receptor não vê o mouse (dormindo ou desligado)"
        case .badField(let a, let d): return String(format: "campo inválido em 0x%04x: ", a) + hex(d)
        case .writeMismatch(let a): return String(format: "a releitura de 0x%04x não bateu; tentei gravar de volta o valor antigo", a)
        case .notSupported(let s): return s
        }
    }
}

/// Protocolo Compx dos mouses ATK e VXE, tirado do ATK HUB. Pedido e resposta vão no report 8, com 16 bytes:
/// [comando, status, endereço BE16, tamanho, 10 bytes de dados, checksum]. O checksum é 0x55 menos a soma do
/// report id e dos 15 primeiros bytes. As configurações moram numa EEPROM lida e gravada em blocos de até 10 bytes.
final class CompxClient: @unchecked Sendable {
    enum Command: UInt8 {
        case mouseOnline = 0x03
        case battery = 0x04
        case writeEeprom = 0x07
        case readEeprom = 0x08
        case cidMid = 0x10
    }

    static let reportID: UInt8 = 8
    let bridge: HIDDeviceBridge

    init(bridge: HIDDeviceBridge) { self.bridge = bridge }

    static func checksum(_ p: [UInt8]) -> UInt8 {
        UInt8(truncatingIfNeeded: 0x55 - p.prefix(15).reduce(Int(reportID)) { $0 + Int($1) })
    }

    /// Cada campo da EEPROM vem seguido de um byte de conferência: 0x55 menos a soma dos bytes do campo.
    static func fieldCheck<S: Sequence<UInt8>>(_ bytes: S) -> UInt8 {
        UInt8(truncatingIfNeeded: 0x55 - bytes.reduce(0) { $0 + Int($1) })
    }

    static func packet(_ cmd: Command, address: Int = 0, length: Int = 0, data: [UInt8] = []) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = cmd.rawValue
        p[2] = UInt8(address >> 8 & 0xff)
        p[3] = UInt8(address & 0xff)
        p[4] = UInt8(max(length, data.count))
        p.replaceSubrange(5..<5 + data.count, with: data)
        p[15] = checksum(p)
        return p
    }

    /// A resposta repete o comando no byte 0 e, nas da EEPROM, o endereço. O ATK HUB espera até 3 s por ela.
    func request(_ p: [UInt8], timeoutMs: Int = 1500, tries: Int = 2) throws -> [UInt8] {
        bridge.requestLock.lock(); defer { bridge.requestLock.unlock() }
        try bridge.open()
        let eeprom = p[0] == Command.readEeprom.rawValue || p[0] == Command.writeEeprom.rawValue
        for _ in 0..<tries {
            _ = bridge.drainInputBodies()
            try bridge.setReport(kIOHIDReportTypeOutput, reportID: Self.reportID, body: p, mode: .embeddedAndParam)
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                for raw in bridge.drainInputBodies() {
                    let r = raw.count > 16 && raw[0] == Self.reportID ? Array(raw.dropFirst()) : raw
                    guard r.count >= 16, r[15] == Self.checksum(r), r[0] == p[0],
                          !eeprom || (r[2] == p[2] && r[3] == p[3]) else { continue }
                    return Array(r.prefix(16))
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        throw CompxError.noResponse(command: p[0])
    }

    // MARK: Comandos

    /// No receptor, diz se o mouse está ligado a ele agora.
    func mouseOnline() throws -> Bool {
        try request(Self.packet(.mouseOnline))[5] == 1
    }

    /// Porcentagem, carregando e tensão em mV.
    func battery() throws -> (percent: Int, charging: Bool, mv: Int) {
        let r = try request(Self.packet(.battery))
        return (Int(r[5]), r[6] == 1, Int(r[7]) << 8 | Int(r[8]))
    }

    /// cid e mid identificam o modelo do mouse, também atrás do receptor.
    func cidMid() throws -> (cid: Int, mid: Int) {
        let r = try request(Self.packet(.cidMid))
        return (Int(r[5]), Int(r[6]))
    }

    func read(_ address: Int, count: Int) throws -> [UInt8] {
        let r = try request(Self.packet(.readEeprom, address: address, length: count))
        return Array(r[5..<5 + count])
    }

    /// Grava e relê. Se a releitura não bater, grava de volta o que havia antes.
    func update(_ address: Int, _ data: [UInt8]) throws {
        let before = try read(address, count: data.count)
        guard before != data else { return }
        _ = try request(Self.packet(.writeEeprom, address: address, data: data))
        guard (try? read(address, count: data.count)) == data else {
            _ = try? request(Self.packet(.writeEeprom, address: address, data: before))
            throw CompxError.writeMismatch(address: address)
        }
    }
}
