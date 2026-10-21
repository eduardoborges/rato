import AppKit
import SwiftUI

/// Um mouse como o painel mostra: uma cópia do último estado, para a view não passar pelos locks do MouseTarget.
struct MouseCard: Identifiable {
    var id: String
    var name: String
    var connection: String
    var modelId: Int?
    var battery: BatteryState?
    var batteryErr: String?
    var batteryAt: Date?
    var settings: MouseSettings?
    var busy = false
    var lastAction: String?
    /// nil na prévia, onde nada vai para o mouse.
    var target: MouseTarget?

    func apply(_ change: SettingChange) {
        if let target { DeviceEngine.shared.apply(change, to: target) }
    }
}

extension MouseCard {
    init(_ t: MouseTarget) {
        self.init(id: t.driver.key, name: t.label, connection: t.driver.connection, modelId: t.driver.modelId,
                  battery: t.battery, batteryErr: t.batteryErr, batteryAt: t.batteryAt, settings: t.settings,
                  busy: t.busy, lastAction: t.lastAction, target: t)
    }

    /// Dados de exemplo para `Rato preview [vazio|aprendendo|dormindo]`.
    static func samples(_ variant: String?) -> [MouseCard] {
        guard variant != "vazio" else { return [] }
        let battery = BatteryState(percent: 65, status: "descarregando", charging: false, voltageMv: 3904, approx: true,
                                   source: "0x1001", hoursLeft: variant == "aprendendo" ? nil : 21.4)
        let settings = MouseSettings(dpiLevels: [400, 800, 1600, 3200], defaultDpiIndex: 2, dpiRange: 100...25600,
                                     dpiStep: 50, reportRateMs: 1, supportedRatesMs: [1, 2, 4, 8],
                                     led: .fixed(0x00, 0xb4, 0xff), ledKinds: [.off, .fixed, .breathe, .cycle])
        return [MouseCard(id: "amostra", name: "G703 LIGHTSPEED Wireless Gaming Mouse", connection: "USB Receiver, slot 1",
                          modelId: 0x4086, battery: battery, batteryErr: variant == "dormindo" ? "sem resposta" : nil,
                          batteryAt: Date().addingTimeInterval(-600), settings: settings)]
    }
}

/// O que o painel mostra. O AppDelegate atualiza a cada mudança no DeviceEngine.
final class PanelModel: ObservableObject {
    @Published var mice: [MouseCard] = []
    @Published var showPercent = UserDefaults.standard.object(forKey: "showPercent") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPercent, forKey: "showPercent"); onChange?() }
    }
    /// Redesenha a barra de menus quando a opção da porcentagem muda.
    var onChange: (() -> Void)?
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.mice.isEmpty { empty }
            ForEach(model.mice) { MouseSection(mouse: $0) }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "computermouse").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("Nenhum mouse encontrado").font(.headline)
            Text("Mexa no mouse para ele acordar. O Rato procura de novo a cada 30 s.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("% na barra", isOn: $model.showPercent).toggleStyle(.switch).controlSize(.mini)
            Spacer()
            Button {
                DeviceEngine.shared.rescan()
                DeviceEngine.shared.refreshAllBatteries(profiles: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Procurar mouses e ler a bateria de novo")
            .glassButton()
            Button("Sair") { NSApp.terminate(nil) }.keyboardShortcut("q").glassButton()
        }
        .font(.callout)
    }
}

private struct MouseSection: View {
    let mouse: MouseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mouse.name).font(.headline)
                    Text(mouse.connection).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mouse.busy {
                    ProgressView().controlSize(.small).help("Gravando no mouse")
                }
            }
            HStack(spacing: 18) {
                MousePhoto(modelId: mouse.modelId, led: mouse.settings?.led).frame(width: 84, height: 150)
                BatteryView(mouse: mouse)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let s = mouse.settings { SettingsView(mouse: mouse, s: s) }
            if let msg = mouse.lastAction {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
    }
}

/// Desenho do mouse com um halo na cor da luz dele.
struct MousePhoto: View {
    let modelId: Int?
    let led: LedEffect?

    var body: some View {
        ZStack {
            glow.blur(radius: 26).opacity(0.6)
            Image(systemName: "computermouse.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    @ViewBuilder private var glow: some View {
        switch led {
        case let .fixed(r, g, b)?, let .breathe(r, g, b, _, _)?:
            Ellipse().fill(rgb(r, g, b))
        case .cycle?:
            Ellipse().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
        default:
            Color.clear
        }
    }
}

private struct BatteryView: View {
    let mouse: MouseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let b = mouse.battery {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    if b.approx, b.percent != nil { Text("≈").font(.title3).foregroundStyle(.secondary) }
                    Text(b.percent.map(String.init) ?? "?")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    if b.charging { Image(systemName: "bolt.fill").foregroundStyle(.green).padding(.leading, 4) }
                }
                if let p = b.percent {
                    ProgressView(value: Double(min(max(p, 0), 100)), total: 100).tint(color(b, p))
                }
                Text(b.status.prefix(1).uppercased() + b.status.dropFirst()).font(.callout)
                if let t = b.timeLeftText {
                    Label(t, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                } else if b.voltageMv != nil, !b.charging {
                    Label("Aprendendo o consumo", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("As horas de uso aparecem depois de algumas horas com o mouse ligado")
                }
                if let mv = b.voltageMv {
                    Text((Double(mv) / 1000).formatted(.number.precision(.fractionLength(2))) + " V")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                if mouse.batteryErr != nil, let at = mouse.batteryAt {
                    Label("lido às \(at.formatted(date: .omitted, time: .shortened))", systemImage: "moon.zzz")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("O mouse está dormindo e não respondeu à última leitura")
                }
            } else if let err = mouse.batteryErr {
                Label("Sem leitura", systemImage: "exclamationmark.triangle").font(.callout)
                Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text("Este mouse não informa a bateria").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ b: BatteryState, _ p: Int) -> Color {
        b.charging ? .green : p <= 15 ? .red : p <= 30 ? .orange : .accentColor
    }
}

private struct SettingsView: View {
    let mouse: MouseCard
    let s: MouseSettings
    @State private var editing = false
    @State private var levels = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !s.dpiLevels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        title("DPI", "cursorarrow.motionlines")
                        Spacer()
                        Button(editing ? "Cancelar" : "Editar") {
                            levels = s.dpiLevels.map(String.init).joined(separator: ", ")
                            editing.toggle()
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    if editing { editor } else {
                        Chips(values: Array(s.dpiLevels.indices), selection: s.defaultDpiIndex,
                              label: { "\(s.dpiLevels[$0])" }) { mouse.apply(.dpiDefault($0)) }
                    }
                }
            }
            if !s.supportedRatesMs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    title("Polling (Hz)", "speedometer")
                    Chips(values: s.supportedRatesMs.sorted(by: >), selection: s.reportRateMs,
                          label: { "\(1000 / max(1, $0))" }) { mouse.apply(.rate(ms: $0)) }
                }
            }
            if !s.ledKinds.isEmpty { LightView(mouse: mouse, s: s) }
        }
        .disabled(mouse.busy)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("400, 800, 1600", text: $levels).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Gravar", action: save).glassButton()
            }
            let range = s.dpiRange.map { ", de \($0.lowerBound) a \($0.upperBound) em passos de \(s.dpiStep)" } ?? ""
            Text("Até 5 valores separados por vírgula\(range).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        editing = false
        let new = levels.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard !new.isEmpty else { return }
        let current = s.dpiLevels.indices.contains(s.defaultDpiIndex) ? s.dpiLevels[s.defaultDpiIndex] : nil
        mouse.apply(.dpi(levels: new, defaultIndex: current.flatMap { new.firstIndex(of: $0) } ?? new.count - 1))
    }
}

private struct LightView: View {
    let mouse: MouseCard
    let s: MouseSettings

    private static let colors: [(String, UInt8, UInt8, UInt8)] = [
        ("Branco", 0xff, 0xff, 0xff), ("Vermelho", 0xff, 0x00, 0x00), ("Laranja", 0xff, 0x80, 0x00),
        ("Amarelo", 0xff, 0xff, 0x00), ("Verde", 0x00, 0xff, 0x00), ("Ciano", 0x00, 0xff, 0xff),
        ("Azul", 0x00, 0x00, 0xff), ("Roxo", 0x80, 0x00, 0xff), ("Rosa", 0xff, 0x00, 0xff),
    ]

    private var kind: LedKind? {
        switch s.led {
        case .off?: return .off
        case .fixed?: return .fixed
        case .breathe?: return .breathe
        case .cycle?: return .cycle
        case nil: return nil
        }
    }

    private var color: (UInt8, UInt8, UInt8)? {
        switch s.led {
        case let .fixed(r, g, b)?, let .breathe(r, g, b, _, _)?: return (r, g, b)
        default: return nil
        }
    }

    /// Período e intensidade atuais. Sem eles, 4 s e 8 s na intensidade máxima.
    private var breath: (Int, Int) { if case let .breathe(_, _, _, p, i)? = s.led { return (p, i) }; return (4000, 100) }
    private var cycle: (Int, Int) { if case let .cycle(p, i)? = s.led { return (p, i) }; return (8000, 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Luz", "lightbulb")
            let kinds = [LedKind.off, .fixed, .breathe, .cycle].filter(s.ledKinds.contains)
            Chips(values: kinds, selection: kind, label: Self.name) { mouse.apply(.led(effect($0, color ?? (0xff, 0xff, 0xff)))) }
            if s.ledKinds.contains(.fixed) || s.ledKinds.contains(.breathe) {
                HStack(spacing: 0) {
                    ForEach(Self.colors, id: \.0) { c in
                        let on = kind != .off && kind != .cycle && color.map { $0 == (c.1, c.2, c.3) } == true
                        Button {
                            mouse.apply(.led(effect(kind == .breathe ? .breathe : .fixed, (c.1, c.2, c.3))))
                        } label: {
                            Circle()
                                .fill(rgb(c.1, c.2, c.3))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().strokeBorder(on ? Color.primary : .clear, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(c.0)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func effect(_ k: LedKind, _ c: (UInt8, UInt8, UInt8)) -> LedEffect {
        switch k {
        case .off: return .off
        case .fixed: return .fixed(c.0, c.1, c.2)
        case .breathe: return .breathe(c.0, c.1, c.2, periodMs: breath.0, intensity: breath.1)
        case .cycle: return .cycle(periodMs: cycle.0, intensity: cycle.1)
        }
    }

    private static func name(_ k: LedKind) -> String {
        switch k {
        case .off: return "Desligada"
        case .fixed: return "Fixa"
        case .breathe: return "Respira"
        case .cycle: return "Ciclo"
        }
    }
}

private func title(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
}

private func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
    Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}
