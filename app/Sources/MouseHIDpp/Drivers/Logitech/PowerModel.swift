import Foundation

/// Modelo de consumo que o G HUB baixa para cada mouse (`battery.xml` no depot). A curva de descarga
/// diz quanta energia já saiu em cada tensão; os blocos dizem quantos mW gastam sensor, MCU, polling
/// e LED. Só é lido do disco: os números são da Logitech e não vêm no repo.
struct PowerModel {
    /// Tensão crescente e mWh já gastos naquela tensão.
    private var curve: [(Double, Double)] = []
    private var baseMw = 0.0
    private var rateMw: [Int: Double] = [:]
    private var ledLoadMw = 0.0
    /// Uma zona de LED por item, na ordem do perfil: tipo do efeito → [(brilho %, mW)].
    private var zones: [[String: [(Double, Double)]]] = []

    static let depots = URL(fileURLWithPath: "/Library/Application Support/Logi/LGHUB/depots")

    /// Procura em depots/*/*/battery.xml o modelo com um dos PIDs do mouse.
    static func load(pids: [Int]) -> PowerModel? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: depots, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            for sub in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard let data = try? Data(contentsOf: sub.appendingPathComponent("battery.xml")),
                      let m = PowerModel(xml: data), pids.contains(m.pid) else { continue }
                hlog("modelo de bateria: \(sub.path)")
                return m
            }
        }
        return nil
    }

    let pid: Int

    init?(xml: Data) {
        // O arquivo da Logitech tem "--" dentro de comentário, o que o XMLDocument recusa.
        let clean = String(decoding: xml, as: UTF8.self).replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        guard let doc = try? XMLDocument(xmlString: clean), let root = doc.rootElement(),
              let pid = root.attribute(forName: "pid")?.stringValue.flatMap({ Int($0.dropFirst(2), radix: 16) }),
              let text = try? doc.nodes(forXPath: "//discharge").first?.stringValue else { return nil }
        self.pid = pid
        // Linhas "minutos,tensão,mWh"; a curva vem em tensão decrescente.
        curve = text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return f.count == 3 ? (f[1], f[2]) : nil
        }.reversed()
        guard curve.count > 1 else { return nil }

        func elements(_ xpath: String) -> [XMLElement] { ((try? doc.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement } }
        func num(_ e: XMLElement, _ attr: String) -> Double? { e.attribute(forName: attr)?.stringValue.flatMap(Double.init) }
        baseMw = elements("//blocks/sensor | //blocks/mcu").compactMap { num($0, "power") }.reduce(0, +)
        for e in elements("//report_rate/interval") {
            if let ms = num(e, "milliseconds"), let mw = num(e, "power") { rateMw[Int(ms)] = mw }
        }
        ledLoadMw = elements("//lighting").first.flatMap { num($0, "mcu_load") } ?? 0
        zones = elements("//lighting/zone").map { zone in
            var effects: [String: [(Double, Double)]] = [:]
            for fx in zone.elements(forName: "effect") {
                guard let type = fx.attribute(forName: "type")?.stringValue else { continue }
                effects[type] = num(fx, "power").map { [(100, $0)] }
                    ?? fx.elements(forName: "brightness").compactMap { b in num(b, "percent").flatMap { p in num(b, "power").map { (p, $0) } } }
                        .sorted { $0.0 < $1.0 }
            }
            return effects
        }
    }

    var capacityMwh: Double { curve.first?.1 ?? 0 }

    /// mWh já gastos com o mouse nesta tensão.
    func usedMwh(volts: Double) -> Double { Self.interp(volts, curve) }

    /// Consumo em uso contínuo. Parado, o mouse dorme e gasta bem menos, então isto é o pior caso.
    func powerMw(rateMs: Int, leds: [LedEffect]) -> Double {
        var mw = baseMw + (rateMw[rateMs] ?? rateMw.values.max() ?? 0)
        for (zone, led) in zip(zones, leds) {
            let (type, percent): (String, Double) = switch led {
            case .off: ("off", 0)
            case let .fixed(r, g, b): ("solid", Double(max(r, g, b)) / 2.55)
            case let .breathe(_, _, _, _, i): ("breathing", Double(i))
            case let .cycle(_, i): ("cycling", Double(i))
            }
            mw += zone[type].map { Self.interp(percent, $0) } ?? 0
        }
        if leds.contains(where: { $0 != .off }) { mw += ledLoadMw }
        return mw
    }

    /// Interpolação linear em pontos com x crescente; fora da faixa, fica na ponta.
    static func interp(_ x: Double, _ pts: [(Double, Double)]) -> Double {
        guard let first = pts.first, let last = pts.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        let i = pts.firstIndex { $0.0 >= x }!
        let (a, b) = (pts[i - 1], pts[i])
        return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
    }
}
