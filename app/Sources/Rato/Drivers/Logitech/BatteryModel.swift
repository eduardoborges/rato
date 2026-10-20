import Foundation

/// Aprende com o próprio mouse quanto tempo de uso cabe em cada faixa de tensão. O G HUB usa uma curva que a
/// Logitech mediu com carga constante e divide a energia restante pelo consumo do perfil. Aqui a curva vem das
/// leituras: o intervalo entre duas leituras com o mouse acordado conta para a faixa de tensão em que ele está.
final class BatteryModel: @unchecked Sendable {
    /// Curva genérica de Li-ion (mV → %), não a da Logitech. Vale até o mouse ensinar a dele.
    static let prior: [(Double, Double)] = [
        (3270, 0), (3610, 5), (3690, 10), (3710, 15), (3730, 20), (3750, 25), (3770, 30), (3790, 35), (3800, 40),
        (3820, 45), (3840, 50), (3850, 55), (3870, 60), (3910, 65), (3950, 70), (3980, 75), (4020, 80), (4080, 85),
        (4110, 90), (4150, 95), (4200, 100),
    ]
    static let binMv = 20
    static let bins = Int(prior.first!.0) / binMv...Int(prior.last!.0) / binMv

    static func priorPercent(_ mv: Int) -> Double { interp(Double(mv), prior) }

    struct Pass: Codable { var seconds = 0.0; var count = 0 }

    struct State: Codable {
        /// Faixa → segundos de uso somados nas passagens completas e o número de passagens.
        var learned: [Int: Pass] = [:]
        var topBin: Int?
        var floorBin: Int?
        var binSeconds = 0.0
        var lastSeen: Date?
    }

    private let file: URL?
    private let lock = NSLock()
    private var state = State()
    private var recent: [Int] = []
    private var median: Int { recent.sorted()[recent.count / 2] }

    /// O aprendizado fica guardado pelo PID do mouse, que não muda com a porta USB.
    convenience init(pid: Int) {
        self.init(file: backupRoot.deletingLastPathComponent().appendingPathComponent(String(format: "bateria-%04x.json", pid)))
    }

    /// Sem arquivo, fica só na memória.
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(State.self, from: data) { state = s }
    }

    /// Registra uma leitura e devolve a % e as horas de uso que faltam (nil até aprender o bastante).
    /// ponytail: a CLI usa o mesmo arquivo. O app regrava o estado dele na leitura seguinte, então só a leitura da CLI se perde.
    func update(mv: Int, charging: Bool, at now: Date = Date()) -> (percent: Int, hoursLeft: Double?) {
        lock.lock(); defer { lock.unlock() }
        record(mv: mv, charging: charging, at: now)
        if let file, let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return forecast(mv: recent.isEmpty ? mv : median)
    }

    func estimate(mv: Int) -> (percent: Int, hoursLeft: Double?) {
        lock.lock(); defer { lock.unlock() }
        return forecast(mv: mv)
    }

    private func record(mv: Int, charging: Bool, at now: Date) {
        guard !charging else { state = State(learned: state.learned); recent = []; return }
        // Mediana das últimas leituras: logo depois de acordar, o mouse mostra uma tensão mais alta por um instante.
        recent = Array((recent + [mv]).suffix(5))
        let bin = median / Self.binMv
        // Mais de 45 s entre leituras quer dizer que o mouse dormiu, e dormindo ele quase não gasta.
        let awake = state.lastSeen.map { now.timeIntervalSince($0) }.flatMap { $0 <= 45 ? $0 : nil } ?? 0
        state.lastSeen = now
        guard let floor = state.floorBin, let top = state.topBin, bin <= floor + 3 else {
            // Primeira leitura, ou a tensão subiu porque o mouse carregou: começa outra descarga.
            state.topBin = bin; state.floorBin = bin; state.binSeconds = 0
            return
        }
        if bin < floor {
            // Só uma passagem inteira ensina. A faixa onde a descarga começou e as quedas de várias faixas de uma vez ficam de fora.
            if bin == floor - 1, floor < top {
                state.learned[floor, default: Pass()].seconds += state.binSeconds
                state.learned[floor, default: Pass()].count += 1
            }
            state.floorBin = bin; state.binSeconds = 0
        }
        state.binSeconds += awake
    }

    private func forecast(mv: Int) -> (percent: Int, hoursLeft: Double?) {
        func span(_ b: Int) -> Double { Self.priorPercent((b + 1) * Self.binMv) - Self.priorPercent(b * Self.binMv) }
        let known = state.learned.filter { $0.value.count > 0 }.mapValues { $0.seconds / Double($0.count) }
        let knownSpan = known.keys.map(span).reduce(0, +)
        // ponytail: 3 faixas é chute. Aumentar se as horas oscilarem muito no começo.
        guard known.count >= 3, knownSpan > 0 else { return (Int(Self.priorPercent(mv).rounded()), nil) }
        // Faixa sem passagem segue a curva genérica, no ritmo (segundos por ponto percentual) das faixas aprendidas.
        let pace = known.values.reduce(0, +) / knownSpan
        func seconds(_ b: Int) -> Double { known[b] ?? pace * span(b) }
        let bin = mv / Self.binMv
        let partial = Self.bins.contains(bin) ? seconds(bin) * Double(mv - bin * Self.binMv) / Double(Self.binMv) : 0
        let left = Self.bins.filter { $0 < bin }.map(seconds).reduce(0, +) + partial
        let total = Self.bins.map(seconds).reduce(0, +)
        // ponytail: o ritmo aprendido é o da luz e do polling de sempre. Mudar a luz deixa as horas erradas até reaprender.
        return (Int((left / total * 100).rounded()), left / 3600)
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
