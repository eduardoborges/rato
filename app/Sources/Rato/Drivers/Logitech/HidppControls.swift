import Foundation

// Leitura e escrita de DPI (0x2201), polling (0x8060), perfis onboard (0x8100)
// e efeitos de LED (0x8071). Índices de função conferidos no libratbag e no Solaar.

extension HidppClient {

    // MARK: DPI (0x2201)

    struct DpiInfo {
        var list: [Int]          // valores discretos, se o sensor listar
        var step: Int?           // passo, quando a lista é um intervalo [min, step, max]
        var current: Int
        var defaultDpi: Int
        var min: Int { list.min() ?? 0 }
        var max: Int { list.max() ?? 0 }
    }

    func dpiInfo() throws -> DpiInfo {
        let f = try feature(HidppFeature.adjustableDpi.rawValue)
        let id = HidppFeature.adjustableDpi.rawValue
        let lp = try call(featureIndex: f.index, featureId: id, funcIdx: 1, params: [0]).p
        var list: [Int] = []
        var step: Int?
        var i = 1
        while i + 1 < lp.count {
            let v = Int(lp[i]) << 8 | Int(lp[i + 1])
            if v == 0 { break }
            if v > 0xe000 { step = v - 0xe000 } else { list.append(v) }
            i += 2
        }
        let cp = try call(featureIndex: f.index, featureId: id, funcIdx: 2, params: [0]).p
        return DpiInfo(list: list, step: step,
                       current: Int(cp[1]) << 8 | Int(cp[2]),
                       defaultDpi: Int(cp[3]) << 8 | Int(cp[4]))
    }

    func setDpi(_ dpi: Int) throws {
        let f = try feature(HidppFeature.adjustableDpi.rawValue)
        _ = try call(featureIndex: f.index, featureId: HidppFeature.adjustableDpi.rawValue,
                     funcIdx: 3, params: [0, UInt8(dpi >> 8), UInt8(dpi & 0xff)])
    }

    // MARK: Polling (0x8060)

    /// Taxas em ms. Bit n da máscara = (n+1) ms.
    func reportRates() throws -> (supported: [Int], current: Int) {
        let f = try feature(HidppFeature.reportRate.rawValue)
        let id = HidppFeature.reportRate.rawValue
        let mask = try call(featureIndex: f.index, featureId: id, funcIdx: 0, params: []).p[0]
        let cur = try call(featureIndex: f.index, featureId: id, funcIdx: 1, params: []).p[0]
        return ((0..<8).filter { mask >> $0 & 1 == 1 }.map { $0 + 1 }, Int(cur))
    }

    func setReportRate(ms: Int) throws {
        let f = try feature(HidppFeature.reportRate.rawValue)
        _ = try call(featureIndex: f.index, featureId: HidppFeature.reportRate.rawValue,
                     funcIdx: 2, params: [UInt8(ms)])
    }

    // MARK: Perfis onboard (0x8100)

    struct OnboardInfo {
        var profiles: Int
        var buttons: Int
        var sectorSize: Int
        var mode: UInt8          // 1 = onboard, 2 = host
        var currentProfile: Int
    }

    func onboardInfo() throws -> OnboardInfo {
        let f = try feature(HidppFeature.onboardProfiles.rawValue)
        let id = HidppFeature.onboardProfiles.rawValue
        let d = try call(featureIndex: f.index, featureId: id, funcIdx: 0, params: []).p
        let mode = try call(featureIndex: f.index, featureId: id, funcIdx: 2, params: []).p[0]
        let cp = try call(featureIndex: f.index, featureId: id, funcIdx: 4, params: []).p
        return OnboardInfo(profiles: Int(d[3]), buttons: Int(d[5]),
                           sectorSize: Int(d[7]) << 8 | Int(d[8]),
                           mode: mode, currentProfile: Int(cp[0]) << 8 | Int(cp[1]))
    }

    func setOnboardMode(host: Bool) throws {
        let f = try feature(HidppFeature.onboardProfiles.rawValue)
        _ = try call(featureIndex: f.index, featureId: HidppFeature.onboardProfiles.rawValue,
                     funcIdx: 1, params: [host ? 0x02 : 0x01])
    }

    struct OnboardProfile {
        var address: UInt16
        var enabled: Bool
        var crcOk: Bool
        var reportRateMs: Int
        var defaultDpiIndex: Int
        var shiftDpiIndex: Int
        var dpis: [Int]
        var leds: [[UInt8]]      // 11 bytes cada: [efeito, parâmetros...]
    }

    /// Lê um setor em blocos de 16 bytes (f5). O último bloco começa em size-16.
    func readSector(_ sector: UInt16, size: Int) throws -> [UInt8] {
        let f = try feature(HidppFeature.onboardProfiles.rawValue)
        var data = [UInt8](repeating: 0, count: size)
        var off = 0
        while off < size {
            let o = min(off, size - 16)
            let p = try call(featureIndex: f.index, featureId: HidppFeature.onboardProfiles.rawValue, funcIdx: 5,
                             params: [UInt8(sector >> 8), UInt8(sector & 0xff), UInt8(o >> 8), UInt8(o & 0xff)]).p
            // Uma resposta curta encolheria o setor e deslocaria o resto dos bytes.
            guard p.count >= 16 else { throw HidppError.unexpectedBody(p) }
            data.replaceSubrange(o..<o + 16, with: p.prefix(16))
            off = o + 16
        }
        return data
    }

    /// CRC-16/CCITT (0xFFFF, 0x1021) dos primeiros size-2 bytes, gravado big endian no fim do setor.
    static func sectorCrc(_ d: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for b in d.dropLast(2) {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    static func sectorCrcOk(_ d: [UInt8]) -> Bool {
        sectorCrc(d) == UInt16(d[d.count - 2]) << 8 | UInt16(d[d.count - 1])
    }

    /// f6 abre a escrita, f7 manda blocos de 16 bytes, f8 fecha. O CRC é recalculado aqui.
    func writeSector(_ sector: UInt16, _ data: [UInt8]) throws {
        let f = try feature(HidppFeature.onboardProfiles.rawValue)
        let id = HidppFeature.onboardProfiles.rawValue
        var d = data
        let crc = Self.sectorCrc(d)
        d[d.count - 2] = UInt8(crc >> 8)
        d[d.count - 1] = UInt8(crc & 0xff)
        let n = d.count
        _ = try call(featureIndex: f.index, featureId: id, funcIdx: 6,
                     params: [UInt8(sector >> 8), UInt8(sector & 0xff), 0, 0, UInt8(n >> 8), UInt8(n & 0xff)])
        d += [UInt8](repeating: 0, count: (16 - n % 16) % 16)
        for o in stride(from: 0, to: d.count, by: 16) {
            _ = try call(featureIndex: f.index, featureId: id, funcIdx: 7, params: Array(d[o..<o + 16]))
        }
        _ = try call(featureIndex: f.index, featureId: id, funcIdx: 8, params: [])
    }

    /// f12: troca o nível de DPI em uso. A recarga do perfil mantém o nível atual.
    func setCurrentDpiIndex(_ i: Int) throws {
        let f = try feature(HidppFeature.onboardProfiles.rawValue)
        _ = try call(featureIndex: f.index, featureId: HidppFeature.onboardProfiles.rawValue,
                     funcIdx: 12, params: [UInt8(i)])
    }

    func setCurrentProfile(_ n: Int) throws {
        let f = try feature(HidppFeature.onboardProfiles.rawValue)
        _ = try call(featureIndex: f.index, featureId: HidppFeature.onboardProfiles.rawValue,
                     funcIdx: 3, params: [0, UInt8(n)])
    }

    /// Diretório e perfis, todos com CRC conferido, gravados em `dir` como sector-XXXX.bin.
    @discardableResult
    func backupSectors(to dir: URL) throws -> [UInt16: [UInt8]] {
        let info = try onboardInfo()
        let directory = try readSector(0x0000, size: info.sectorSize)
        var sectors: [UInt16: [UInt8]] = [0x0000: directory]
        for i in 0..<info.profiles {
            let addr = UInt16(directory[4 * i]) << 8 | UInt16(directory[4 * i + 1])
            if addr == 0xffff { break }
            sectors[addr] = try readSector(addr, size: info.sectorSize)
        }
        for (addr, d) in sectors where !Self.sectorCrcOk(d) {
            throw HidppError.notSupported(String(format: "setor 0x%04x com CRC ruim; nada foi gravado", addr))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (addr, d) in sectors {
            try Data(d).write(to: dir.appendingPathComponent(String(format: "sector-%04x.bin", addr)))
        }
        return sectors
    }

    /// Grava de volta os setores de um backup e recarrega o perfil atual.
    func restoreSectors(from dir: URL) throws {
        profileLock.lock(); defer { profileLock.unlock() }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("sector-") }
        for name in files.sorted() {
            guard let addr = UInt16(name.dropFirst(7).prefix(4), radix: 16) else { continue }
            let d = [UInt8](try Data(contentsOf: dir.appendingPathComponent(name)))
            guard Self.sectorCrcOk(d) else { throw HidppError.notSupported("\(name) com CRC ruim") }
            try writeSector(addr, d)
            guard try readSector(addr, size: d.count) == d else { throw HidppError.notSupported("\(name) não confere depois de gravar") }
        }
        try setCurrentProfile(try onboardInfo().currentProfile)
    }

    /// Edita o perfil ativo: backup, escrita, releitura byte a byte e recarga.
    /// Se a releitura não bate, grava o original de volta.
    @discardableResult
    func editActiveProfile(_ edit: (inout [UInt8]) throws -> Void) throws -> URL {
        profileLock.lock(); defer { profileLock.unlock() }
        let info = try onboardInfo()
        guard info.mode == 1 else { throw HidppError.notSupported("mouse fora do modo onboard") }
        let dir = newBackupDir()
        let sectors = try backupSectors(to: dir)
        let directory = sectors[0x0000]!
        let n = info.currentProfile
        let addr = UInt16(directory[4 * (n - 1)]) << 8 | UInt16(directory[4 * (n - 1) + 1])
        guard let orig = sectors[addr] else { throw HidppError.notSupported("perfil \(n) fora do diretório") }
        var d = orig
        try edit(&d)
        let crc = Self.sectorCrc(d)
        d[d.count - 2] = UInt8(crc >> 8)
        d[d.count - 1] = UInt8(crc & 0xff)
        guard d != orig else { return dir }
        try writeSector(addr, d)
        guard try readSector(addr, size: d.count) == d else {
            try? writeSector(addr, orig)
            throw HidppError.notSupported("perfil não confere depois de gravar; original regravado (backup em \(dir.path))")
        }
        try setCurrentProfile(n)
        return dir
    }

    @discardableResult
    func apply(_ change: SettingChange) throws -> URL {
        switch change {
        case let .dpi(levels, def):
            let sensor = try dpiInfo()
            let dir = try editActiveProfile { try Self.setDpiLevels(levels, defaultIndex: def, sensor: sensor, in: &$0) }
            try setCurrentDpiIndex(def)
            return dir
        case let .dpiDefault(i):
            let dir = try editActiveProfile { d in
                let count = (0..<5).filter { d[3 + 2 * $0] != 0 || d[4 + 2 * $0] != 0 }.count
                guard (0..<count).contains(i) else { throw HidppError.notSupported("nível \(i + 1) não existe (há \(count))") }
                d[1] = UInt8(i)
            }
            try setCurrentDpiIndex(i)
            return dir
        case let .rate(ms):
            let supported = try reportRates().supported
            guard supported.contains(ms) else { throw HidppError.notSupported("polling \(ms) ms fora de \(supported) ms") }
            return try editActiveProfile { $0[0] = UInt8(ms) }
        case let .led(e):
            releaseLedSoftwareControl()
            return try editActiveProfile { Self.setLed(e, in: &$0) }
        }
    }

    // MARK: Campos do perfil

    static func setDpiLevels(_ levels: [Int], defaultIndex: Int, sensor: DpiInfo, in d: inout [UInt8]) throws {
        guard (1...5).contains(levels.count), levels.indices.contains(defaultIndex) else {
            throw HidppError.notSupported("de 1 a 5 níveis, padrão entre 1 e \(levels.count)")
        }
        for v in levels where v < sensor.min || v > sensor.max || (v - sensor.min) % (sensor.step ?? 1) != 0 {
            throw HidppError.notSupported("DPI \(v) fora de \(sensor.min)...\(sensor.max) passo \(sensor.step ?? 1)")
        }
        for i in 0..<5 {
            let v = i < levels.count ? levels[i] : 0
            d[3 + 2 * i] = UInt8(v & 0xff)
            d[4 + 2 * i] = UInt8(v >> 8)
        }
        d[1] = UInt8(defaultIndex)
    }

    static func setLed(_ e: LedEffect, in d: inout [UInt8]) {
        let b = e.hidppProfileBytes
        d.replaceSubrange(208..<219, with: b)
        d.replaceSubrange(219..<230, with: b)
    }

    /// Solta o controle de software do 0x8071 para o LED voltar a seguir o perfil.
    func releaseLedSoftwareControl() {
        guard let f = tryFeature(HidppFeature.rgbEffects8071.rawValue) else { return }
        _ = try? call(featureIndex: f.index, featureId: HidppFeature.rgbEffects8071.rawValue,
                      funcIdx: 5, params: [0x01, 0x00, 0x00])
    }

    static func parseProfile(address: UInt16, enabled: Bool, _ d: [UInt8]) -> OnboardProfile {
        OnboardProfile(
            address: address, enabled: enabled, crcOk: sectorCrcOk(d),
            reportRateMs: Int(d[0]), defaultDpiIndex: Int(d[1]), shiftDpiIndex: Int(d[2]),
            dpis: (0..<5).map { Int(d[3 + 2 * $0]) | Int(d[4 + 2 * $0]) << 8 },
            leds: [Array(d[208..<219]), Array(d[219..<230])])
    }

    func onboardProfiles() throws -> [OnboardProfile] {
        let info = try onboardInfo()
        let dir = try readSector(0x0000, size: info.sectorSize)
        return try (0..<info.profiles).compactMap { i -> OnboardProfile? in
            let addr = UInt16(dir[4 * i]) << 8 | UInt16(dir[4 * i + 1])
            guard addr != 0xffff else { return nil }
            return Self.parseProfile(address: addr, enabled: dir[4 * i + 2] != 0, try readSector(addr, size: info.sectorSize))
        }
    }

    /// Perfil em uso. Com CRC ruim, lê de novo uma vez: o painel mostraria bytes corrompidos como se fossem o perfil.
    func activeProfile() throws -> OnboardProfile {
        for _ in 0..<2 {
            let info = try onboardInfo()
            let dir = try readSector(0x0000, size: info.sectorSize)
            let i = info.currentProfile - 1
            guard (0..<info.profiles).contains(i) else { throw HidppError.notSupported("sem perfil ativo (modo host?)") }
            let addr = UInt16(dir[4 * i]) << 8 | UInt16(dir[4 * i + 1])
            let p = Self.parseProfile(address: addr, enabled: dir[4 * i + 2] != 0, try readSector(addr, size: info.sectorSize))
            if p.crcOk { return p }
            hlog(String(format: "\(devLabel): perfil @0x%04x com CRC ruim", addr))
        }
        throw HidppError.notSupported("perfil ativo com CRC ruim")
    }

    // MARK: LED (0x8071)

    struct LedCluster {
        var index: UInt8
        var location: Int
        var effects: [UInt16]    // ID de cada efeito, na ordem do índice
    }

    func ledClusters() throws -> [LedCluster] {
        let f = try feature(HidppFeature.rgbEffects8071.rawValue)
        let id = HidppFeature.rgbEffects8071.rawValue
        let dev = try call(featureIndex: f.index, featureId: id, funcIdx: 0, params: [0xff, 0xff, 0x00]).p
        return try (0..<dev[2]).map { c in
            let ci = try call(featureIndex: f.index, featureId: id, funcIdx: 0, params: [c, 0xff, 0x00],
                              accept: { $0.p.first == c }).p
            let effects = try (0..<ci[4]).map { e -> UInt16 in
                let ei = try call(featureIndex: f.index, featureId: id, funcIdx: 0, params: [c, e, 0x00],
                                  accept: { $0.p.first == c && $0.p[1] == e }).p
                return UInt16(ei[2]) << 8 | UInt16(ei[3])
            }
            return LedCluster(index: c, location: Int(ci[2]) << 8 | Int(ci[3]), effects: effects)
        }
    }
}

extension LedEffect {
    /// 11 bytes no formato do perfil: ID do efeito e parâmetros (layout do libratbag).
    var hidppProfileBytes: [UInt8] {
        var b = [UInt8](repeating: 0, count: 11)
        switch self {
        case .off: break
        case let .fixed(r, g, bl):
            b[0] = 0x01; b[1] = r; b[2] = g; b[3] = bl
        case let .breathe(r, g, bl, p, i):
            b[0] = 0x0a; b[1] = r; b[2] = g; b[3] = bl
            b[4] = UInt8(p >> 8); b[5] = UInt8(p & 0xff); b[7] = UInt8(i)
        case let .cycle(p, i):
            b[0] = 0x03; b[6] = UInt8(p >> 8); b[7] = UInt8(p & 0xff); b[8] = UInt8(i)
        }
        return b
    }

    init?(hidppProfileBytes b: [UInt8]) {
        switch b[0] {
        case 0x00: self = .off
        case 0x01: self = .fixed(b[1], b[2], b[3])
        case 0x0a: self = .breathe(b[1], b[2], b[3], periodMs: Int(b[4]) << 8 | Int(b[5]), intensity: b[7] == 0 ? 100 : Int(b[7]))
        case 0x03: self = .cycle(periodMs: Int(b[6]) << 8 | Int(b[7]), intensity: b[8] == 0 ? 100 : Int(b[8]))
        default: return nil
        }
    }
}
