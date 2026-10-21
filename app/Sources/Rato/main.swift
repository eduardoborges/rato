import Foundation
import AppKit

// Rato: bateria, DPI, polling e LED de mouses por HID. Cada fabricante tem um driver
// em Drivers/; mouse sem driver próprio cai no genérico, que só mostra a bateria Bluetooth.
//
//   Rato                                   menu bar
//   Rato probe | state                     qualquer mouse
//   Rato set dpi <níveis> <padrão>         ex.: set dpi 400,800,1600,3200 4
//   Rato set dpi-default <n>
//   Rato set rate <ms>
//   Rato set led off | color RRGGBB | breathe RRGGBB | cycle
//   Rato profiles | features | backup | restore <pasta> | mode host|onboard    só Logitech
//   Rato selftest
//   Rato preview [vazio|aprendendo|dormindo]   o painel com dados de exemplo, sem HID

extension Drivers {
    /// Drivers de fabricante vêm antes; o genérico fica por último.
    static let all: [MouseDriverType.Type] = [LogitechDriver.self, GenericDriver.self]
}

enum CLI {
    static func run(_ cmd: String) -> Never {
        hlog("Rato — modo `\(cmd)`")
        if LogitechDriver.gHubAgentRunning() {
            guard !["restore", "mode"].contains(cmd) else {
                hlog("feche o G HUB antes de gravar no mouse (lghub_agent rodando)")
                exit(75)
            }
            hlog("lghub_agent rodando: as leituras podem disputar o canal HID++")
        }
        let args = Array(CommandLine.arguments.dropFirst(2))
        let engine = DeviceEngine.shared
        engine.start()
        _ = engine.scan(waitSeconds: 20)
        let targets = engine.snapshot()
        guard !targets.isEmpty else {
            hlog("nenhum mouse encontrado (Logitech sem resposta? G HUB aberto?)")
            exit(2)
        }
        let logitech = targets.compactMap { $0.driver as? LogitechDriver }

        switch cmd {
        case "probe":
            hlog("\(targets.count) mouse(s):")
            for t in targets {
                print("=== \(t.label)")
                t.driver.details.forEach { print("    \($0)") }
                if let b = t.battery { print("    bateria   : \(b)") }
                else if let err = t.batteryErr { print("    bateria   : ERRO \(err)") }
                else { print("    bateria   : n/a") }
            }
        case "state":
            for t in targets {
                print("=== \(t.label)")
                if let s = t.settings {
                    let levels = s.dpiLevels.enumerated().map { $0.offset == s.defaultDpiIndex ? "[\($0.element)]" : "\($0.element)" }
                    let range = s.dpiRange.map { "; aceita \($0.lowerBound)...\($0.upperBound) passo \(s.dpiStep)" } ?? ""
                    print("    dpi       : \(levels.joined(separator: " "))\(range)")
                    print("    polling   : \(s.reportRateMs) ms (aceita \(s.supportedRatesMs.map(String.init).joined(separator: "/")) ms)")
                    print("    led       : \(s.led.map { "\($0)" } ?? "?") (aceita \(s.ledKinds.map { "\($0)" }.joined(separator: ", ")))")
                } else {
                    print("    ajustes   : nenhum (driver só lê)")
                }
                if let lg = t.driver as? LogitechDriver {
                    if let d = try? lg.client.dpiInfo() { print("    dpi agora : \(d.current)") }
                    if let o = try? lg.client.onboardInfo() {
                        print("    onboard   : modo \(o.mode == 1 ? "onboard" : o.mode == 2 ? "host" : "?"), perfil \(o.currentProfile) de \(o.profiles)")
                    }
                }
                if let b = t.battery { print("    bateria   : \(b)") }
            }
        case "set":
            guard let change = parseChange(args) else {
                hlog("uso: set dpi <níveis> <padrão> | dpi-default <n> | rate <ms> | led off|color RRGGBB|breathe RRGGBB|cycle")
                exit(64)
            }
            for t in targets {
                do { try t.driver.apply(change); hlog("\(t.label): ok") }
                catch { hlog("\(t.label): ERRO \(error)") }
            }
        case "mode":
            let host: Bool
            switch args.first {
            case "host": host = true
            case "onboard": host = false
            default: hlog("uso: mode host|onboard"); exit(64)
            }
            for lg in logitech {
                do { try lg.client.setOnboardMode(host: host); hlog("\(lg.name): modo \(host ? "host" : "onboard") ok") }
                catch { hlog("\(lg.name): modo ERRO \(error)") }
            }
        case "profiles":
            for lg in logitech {
                print("=== \(lg.name)")
                do {
                    for (i, pr) in try lg.client.onboardProfiles().enumerated() {
                        let dpis = pr.dpis.enumerated().map { $0.offset == pr.defaultDpiIndex ? "[\($0.element)]" : "\($0.element)" }
                        print(String(format: "    perfil %d @0x%04x %@ crc %@: %d ms, dpi %@ (shift: nível %d)",
                                     i + 1, pr.address, pr.enabled ? "ativo" : "inativo", pr.crcOk ? "ok" : "RUIM",
                                     pr.reportRateMs, dpis.joined(separator: " "), pr.shiftDpiIndex))
                        for (n, led) in pr.leds.enumerated() { print("        led\(n): \(hex(led))") }
                    }
                } catch {
                    print("    ERRO \(error)")
                }
            }
        case "features":
            for lg in logitech {
                print("=== \(lg.name)")
                do {
                    for f in try lg.client.listFeatures() {
                        print(String(format: "    0x%02x  0x%04x  v%u  tipo 0x%02x", f.index, f.id, f.version, f.type))
                    }
                } catch {
                    print("    ERRO \(error)")
                }
            }
        case "backup":
            for lg in logitech {
                let dir = newBackupDir()
                do { try lg.client.backupSectors(to: dir); hlog("\(lg.name): backup em \(dir.path)") }
                catch { hlog("\(lg.name): ERRO \(error)") }
            }
        case "restore":
            guard let path = args.first else { hlog("uso: restore <pasta do backup>"); exit(64) }
            for lg in logitech {
                do { try lg.client.restoreSectors(from: URL(fileURLWithPath: path)); hlog("\(lg.name): restaurado de \(path)") }
                catch { hlog("\(lg.name): ERRO \(error)") }
            }
        default:
            break
        }
        exit(0)
    }
}

/// Confere o roteamento de drivers, o parser de bateria Bluetooth e o modelo de bateria. Sai com erro se algo quebrar.
func selftest() -> Never {
    precondition(Drivers.route(vendorID: 0x046D) == LogitechDriver.self, "Logitech vai para o driver HID++")
    precondition(Drivers.route(vendorID: 0x1532) == GenericDriver.self, "fabricante sem driver cai no genérico")
    precondition(Drivers.route(vendorID: 0, in: [LogitechDriver.self]) == nil, "sem genérico, nada é roteado")
    let json = """
    {"SPBluetoothDataType":[{"device_connected":[
      {"MX Anywhere":{"device_minorType":"Mouse","device_vendorID":"0x046D","device_productID":"0xB023","device_batteryLevelMain":"80%"}},
      {"Tally":{"device_minorType":"Keyboard","device_vendorID":"0x02E5","device_batteryLevelMain":"100%"}}]}]}
    """
    let parsed = BluetoothBattery.parse(Data(json.utf8))
    precondition(parsed.count == 2)
    precondition(parsed.filter { isMouse($0.minorType) } == [BluetoothBattery.Device(
        name: "MX Anywhere", minorType: "Mouse", vendorID: 0x046D, productID: 0xB023, percent: 80)])
    let blank = BatteryModel(file: nil)
    precondition(blank.update(mv: 3840, charging: false) == (50, nil), "sem aprender, % da curva genérica e sem horas")
    // Descarga sintética: 20 mV a cada 15 min de uso, leitura a cada 30 s com ruído e um cochilo de 10 min a cada 50 leituras.
    let m = BatteryModel(file: nil)
    var clock = Date(timeIntervalSince1970: 0), used = 0.0, i = 0
    while 4180 - Int(used / 900 * 20) >= 3500 {
        _ = m.update(mv: 4180 - Int(used / 900 * 20) + (i * 37) % 17 - 8, charging: false, at: clock)
        i += 1; used += 30; clock += i % 50 == 0 ? 630 : 30
    }
    let half = m.estimate(mv: 3840), low = m.estimate(mv: 3700)
    precondition(abs(half.percent - 50) <= 3 && abs(half.hoursLeft! - 4.25) < 0.25, "aprende o ritmo: 50% e ~4,25 h no meio")
    precondition(abs(low.percent - 29) <= 3, "a curva aprendida vence a genérica, que daria 10%")
    for d in BluetoothBattery.connected({ _ in true }) {
        print("    bluetooth : \(d.name) [\(d.minorType)] \(d.percent.map { "\($0)%" } ?? "sem bateria")")
    }
    print("selftest ok")
    exit(0)
}

func parseChange(_ a: [String]) -> SettingChange? {
    func rgb(_ h: String?) -> (UInt8, UInt8, UInt8)? {
        guard let h, h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (UInt8(v >> 16), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
    }
    switch (a.first, a.count) {
    case ("dpi", 3):
        let levels = a[1].split(separator: ",").compactMap { Int($0) }
        guard let n = Int(a[2]) else { return nil }
        return .dpi(levels: levels, defaultIndex: n - 1)
    case ("dpi-default", 2): return Int(a[1]).map { .dpiDefault($0 - 1) }
    case ("rate", 2): return Int(a[1]).map { .rate(ms: $0) }
    case ("led", _):
        switch a.dropFirst().first {
        case "off": return .led(.off)
        case "cycle": return .led(.cycle(periodMs: 8000, intensity: 100))
        case "color": return rgb(a.dropFirst(2).first).map { .led(.fixed($0.0, $0.1, $0.2)) }
        case "breathe": return rgb(a.dropFirst(2).first).map { .led(.breathe($0.0, $0.1, $0.2, periodMs: 4000, intensity: 100)) }
        default: return nil
        }
    default: return nil
    }
}

func startMenuBarApp(sample: [MouseCard]? = nil) -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate(sample: sample)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

// Fora de um terminal (open --stdout, launchd) o print ficaria no buffer até o app sair.
setvbuf(stdout, nil, _IOLBF, 0)

switch CommandLine.arguments.dropFirst().first {
case "selftest": selftest()
case "preview": startMenuBarApp(sample: MouseCard.samples(CommandLine.arguments.dropFirst(2).first))
case let c? where ["probe", "state", "profiles", "features", "set", "backup", "restore", "mode"].contains(c): CLI.run(c)
default: startMenuBarApp()
}
