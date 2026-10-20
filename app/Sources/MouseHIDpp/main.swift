import Foundation
import AppKit

// MouseHIDpp: DPI, polling, LED e bateria de mouse Logitech por HID++ (IOHIDManager, sem G HUB).
//
//   MouseHIDpp                                   menu bar
//   MouseHIDpp probe | state | profiles | features
//   MouseHIDpp set dpi <níveis> <padrão>         ex.: set dpi 400,800,1600,3200 4
//   MouseHIDpp set dpi-default <n>
//   MouseHIDpp set rate <ms>
//   MouseHIDpp set led off | color RRGGBB | breathe RRGGBB | cycle
//   MouseHIDpp backup | restore <pasta>
//   MouseHIDpp mode host | onboard

enum CLI {
    static func run(_ cmd: String) -> Never {
        hlog("MouseHIDpp — modo `\(cmd)`")
        if gHubAgentRunning() {
            guard !["set", "restore", "mode"].contains(cmd) else {
                hlog("feche o G HUB antes de gravar no mouse (lghub_agent rodando)")
                exit(75)
            }
            hlog("lghub_agent rodando: as leituras podem disputar o canal HID++")
        }
        let args = Array(CommandLine.arguments.dropFirst(2))
        let engine = DeviceEngine.shared
        engine.start()
        _ = engine.scan(waitSeconds: 20)
        let targets = engine.snapshot().filter { t in
            if case .none = t.lighting { return t.battery != nil }
            return true
        }
        guard !targets.isEmpty else {
            hlog("nenhum device Logitech com HID++ respondendo (mouse no USB/BT? G HUB encerrado?)")
            exit(2)
        }

        switch cmd {
        case "probe":
            hlog("\(targets.count) dispositivo(s) HID++:")
            for t in targets {
                print("=== \(t.label)")
                print("    hw        : \(t.bridge.description)")
                if let b = t.battery { print("    bateria   : \(b)") }
                else if let err = t.batteryErr { print("    bateria   : ERRO \(err)") }
                else { print("    bateria   : n/a") }
                print("    lighting  : \(t.lighting.description)")
            }
        case "state":
            for t in targets {
                let c = t.client
                print("=== \(t.label)")
                do {
                    let d = try c.dpiInfo()
                    let range = d.step.map { "\(d.min)...\(d.max) passo \($0)" } ?? d.list.map(String.init).joined(separator: ", ")
                    print("    dpi       : \(d.current) (padrão \(d.defaultDpi); \(range))")
                } catch { print("    dpi       : ERRO \(error)") }
                do {
                    let r = try c.reportRates()
                    print("    polling   : \(r.current) ms (aceita \(r.supported.map { "\($0)" }.joined(separator: "/")) ms)")
                } catch { print("    polling   : ERRO \(error)") }
                do {
                    let o = try c.onboardInfo()
                    let mode = o.mode == 1 ? "onboard" : o.mode == 2 ? "host" : "0x\(String(o.mode, radix: 16))"
                    print("    onboard   : modo \(mode), perfil \(o.currentProfile) de \(o.profiles), \(o.buttons) botões, setor \(o.sectorSize) B")
                } catch { print("    onboard   : ERRO \(error)") }
                do {
                    for cl in try c.ledClusters() {
                        let fx = cl.effects.map { String(format: "0x%02x", $0) }.joined(separator: " ")
                        print("    led clu\(cl.index) : local \(cl.location), efeitos [\(fx)]")
                    }
                } catch { print("    led       : ERRO \(error)") }
                if let b = t.battery { print("    bateria   : \(b)") }
            }
        case "mode":
            let host: Bool
            switch args.first {
            case "host": host = true
            case "onboard": host = false
            default: hlog("uso: mode host|onboard"); exit(64)
            }
            for t in targets {
                do { try t.client.setOnboardMode(host: host); hlog("\(t.label): modo \(host ? "host" : "onboard") ok") }
                catch { hlog("\(t.label): modo ERRO \(error)") }
            }
        case "profiles":
            for t in targets {
                print("=== \(t.label)")
                do {
                    for (i, pr) in try t.client.onboardProfiles().enumerated() {
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
            for t in targets {
                print("=== \(t.label)")
                do {
                    for f in try t.client.listFeatures() {
                        print(String(format: "    0x%02x  0x%04x  v%u  tipo 0x%02x", f.index, f.id, f.version, f.type))
                    }
                } catch {
                    print("    ERRO \(error)")
                }
            }
        case "set":
            guard let change = parseChange(args) else {
                hlog("uso: set dpi <níveis> <padrão> | dpi-default <n> | rate <ms> | led off|color RRGGBB|breathe RRGGBB|cycle")
                exit(64)
            }
            for t in targets {
                do { hlog("\(t.label): gravado (backup em \(try t.client.apply(change).path))") }
                catch { hlog("\(t.label): ERRO \(error)") }
            }
        case "backup":
            for t in targets {
                let dir = newBackupDir()
                do { try t.client.backupSectors(to: dir); hlog("\(t.label): backup em \(dir.path)") }
                catch { hlog("\(t.label): ERRO \(error)") }
            }
        case "restore":
            guard let path = args.first else { hlog("uso: restore <pasta do backup>"); exit(64) }
            for t in targets {
                do { try t.client.restoreSectors(from: URL(fileURLWithPath: path)); hlog("\(t.label): restaurado de \(path)") }
                catch { hlog("\(t.label): ERRO \(error)") }
            }
        default:
            break
        }
        exit(0)
    }
}

func parseChange(_ a: [String]) -> HidppClient.ProfileChange? {
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

func startMenuBarApp() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

switch CommandLine.arguments.dropFirst().first {
case let c? where ["probe", "state", "profiles", "features", "set", "backup", "restore", "mode"].contains(c): CLI.run(c)
default: startMenuBarApp()
}
