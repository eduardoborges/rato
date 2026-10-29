/// Sensor do mouse. O jeito de guardar o DPI na EEPROM muda com ele.
enum CompxSensor: String {
    case paw3955 = "PAW3955", paw3950Ultra = "PAW3950Ultra", paw3950 = "PAW3950", paw3395Ultra = "PAW3395Ultra",
         paw3395 = "PAW3395", paw3395SE = "PAW3395SE", xHeroAI3311 = "XHeroAI3311", paw3311 = "PAW3311", paw3320 = "PAW3320"

    /// Os limites do editor de DPI do ATK HUB.
    var limits: (range: ClosedRange<Int>, step: Int) {
        switch self {
        case .paw3955: return (1...50000, 1)
        case .paw3950Ultra: return (10...42000, 10)
        case .paw3950: return (50...36000, 50)
        case .paw3395Ultra, .paw3395: return (100...30000, 50)
        case .paw3395SE: return (200...18000, 50)
        case .xHeroAI3311, .paw3311: return (200...15000, 100)
        case .paw3320: return (200...4000, 39)
        }
    }

    /// O passo engrossa nos valores altos, porque o nível guarda 10 bits e um bit que dobra o valor.
    var coarseSteps: String {
        switch self {
        case .paw3950Ultra: return " (50 acima de 10000, 100 acima de 30000)"
        case .paw3950: return " (100 acima de 30000)"
        default: return ""
        }
    }

    /// O 3395SE e o 3311 usam uma tabela de valores, e o 3320 outra conta. Os três ficam de fora por enquanto.
    var converts: Bool { encode(1000) != nil }

    /// Endereço do nível i e o tamanho dele, sem o byte de conferência. O 3955 guarda 16 bits por eixo em outra área.
    func slot(_ i: Int) -> (address: Int, size: Int) {
        self == .paw3955 ? (0x1B00 + 6 * i, 5) : (0x0C + 4 * i, 3)
    }

    /// Grava o mesmo valor nos dois eixos. No byte extra, os bits 2-3 e 6-7 são os bits altos de x e y, 0x02 e 0x20
    /// marcam a faixa acima de 10000 no 3950 Ultra, e 0x01 e 0x10 dobram o valor.
    func encode(_ dpi: Int) -> [UInt8]? {
        switch self {
        case .paw3955:
            guard (1...65536).contains(dpi) else { return nil }
            let base = dpi - 1
            return [UInt8(base & 0xff), UInt8(base >> 8), UInt8(base & 0xff), UInt8(base >> 8), 0]
        case .paw3950Ultra:
            let high = dpi > 10000, double = dpi > 30000
            let r = high ? ((double ? dpi / 2 : dpi) - 10050) / 50 : dpi / 10 - 1
            return pack(r, flags: (high ? 0x22 : 0) | (double ? 0x11 : 0))
        case .paw3950, .paw3395Ultra, .paw3395:
            let double = dpi > 30000
            return pack(dpi / (double ? 100 : 50) - 1, flags: double ? 0x11 : 0)
        case .paw3395SE, .xHeroAI3311, .paw3311, .paw3320:
            return nil
        }
    }

    /// Lê o eixo x, como o ATK HUB.
    func decode(_ b: [UInt8]) -> Int? {
        switch self {
        case .paw3955:
            let v = (Int(b[0]) | Int(b[1]) << 8) + 1
            return b[4] & 0x01 != 0 ? v * 2 : v
        case .paw3950Ultra:
            let r = Int(b[0]) | Int(b[2] & 0x0c) << 6
            let v = b[2] & 0x02 != 0 ? 50 * r + 10050 : 10 * (r + 1)
            return b[2] & 0x01 != 0 ? v * 2 : v
        case .paw3950, .paw3395Ultra, .paw3395:
            let v = 50 * (1 + (Int(b[0]) | Int(b[2] & 0x0c) << 6))
            return b[2] & 0x01 != 0 ? v * 2 : v
        case .paw3395SE, .xHeroAI3311, .paw3311, .paw3320:
            return nil
        }
    }

    /// Aceita só os valores que voltam iguais depois da conversão.
    func accepts(_ dpi: Int) -> Bool {
        limits.range.contains(dpi) && encode(dpi).flatMap(decode) == dpi
    }

    private func pack(_ r: Int, flags: Int) -> [UInt8]? {
        guard (0...1023).contains(r) else { return nil }
        let hi = r >> 8 & 3
        return [UInt8(r & 0xff), UInt8(r & 0xff), UInt8(hi << 6 | hi << 2 | flags)]
    }
}
