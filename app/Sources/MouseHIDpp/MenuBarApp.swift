import AppKit

/// Menu-bar: título com % de bateria do primeiro device; dropdown com
/// uma linha por device (bateria) + checkbox "Apagar LEDs".
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var batteryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let engine = DeviceEngine.shared
        engine.onChanged = { [weak self] in self?.rebuild() }
        engine.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        self.statusItem = item
        rebuild()

        // Enumeração inicial (a thread HID cuida dos callbacks).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = engine.scan(waitSeconds: 2.5)
            DispatchQueue.main.async { self?.rebuild() }
        }

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            DeviceEngine.shared.refreshAllBatteries()
        }
    }

    // MARK: Ícones

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private static func batterySymbol(_ b: BatteryState) -> String {
        if b.status == "carregando" { return "battery.100percent.bolt" }
        guard let p = b.percent else { return "battery.50percent" }
        return "battery.\(min(100, (p + 12) / 25 * 25))percent"
    }

    /// Mouse em template que enche de baixo para cima conforme a bateria, como o ícone de bateria do sistema.
    private static func mouseIcon(level: Int?, charging: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 10, height: 16), xRadius: 5, yRadius: 5)
            body.lineWidth = 1.2
            body.stroke()
            if let level {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: NSRect(x: 2.6, y: 2.6, width: 6.8, height: 12.8), xRadius: 3.4, yRadius: 3.4).addClip()
                NSBezierPath(rect: NSRect(x: 0, y: 2.6, width: 12, height: 12.8 * CGFloat(min(max(level, 0), 100)) / 100)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            // Com xor, o traço vira recorte onde há preenchimento e aparece onde está vazio.
            if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
                bolt.draw(in: NSRect(x: 3, y: 4.5, width: 6, height: 9), from: .zero, operation: .xor, fraction: 1)
            } else {
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: 6, y: 16.4))
                divider.line(to: NSPoint(x: 6, y: 11))
                divider.lineWidth = 1.2
                NSGraphicsContext.current?.compositingOperation = .xor
                divider.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func levelText(_ b: BatteryState) -> String {
        b.percent.map { "\(b.approx ? "≈" : "")\($0)%" } ?? b.voltageMv.map { "\($0)mV" } ?? "?"
    }

    private static func batteryLine(_ t: MouseTarget) -> (symbol: String, text: String) {
        if let b = t.battery { return (batterySymbol(b), "\(levelText(b))  •  \(b.status)") }
        if let err = t.batteryErr { return ("exclamationmark.triangle", err) }
        return ("battery.0percent", "n/a")
    }

    private var showPercent: Bool {
        get { UserDefaults.standard.object(forKey: "showPercent") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showPercent") }
    }

    // MARK: Menu

    private func rebuild() {
        guard let item = statusItem else { return }
        let engine = DeviceEngine.shared
        let targets = engine.snapshot()

        if let button = item.button {
            // preferência: 1º device com % real
            let b = targets.first(where: { $0.battery?.percent != nil })?.battery
                ?? targets.lazy.compactMap(\.battery).first
            let text = b.map(Self.levelText)
            let icon = Self.mouseIcon(level: b?.percent, charging: b?.status == "carregando")
            icon.accessibilityDescription = text.map { "Bateria do mouse \($0)" } ?? "Nenhum mouse"
            button.image = icon
            button.title = showPercent ? text ?? "" : ""
            button.appearsDisabled = targets.isEmpty
        }

        let menu = item.menu ?? NSMenu()
        menu.removeAllItems()
        menu.autoenablesItems = false

        if targets.isEmpty {
            let none = NSMenuItem(title: "Nenhum mouse HID++ Logitech encontrado", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for t in targets {
                let line = Self.batteryLine(t)
                let bi = NSMenuItem(title: "\(t.label)  —  \(line.text)",
                                    action: nil, keyEquivalent: "")
                bi.image = Self.symbol(line.symbol, "Bateria")
                bi.isEnabled = false
                menu.addItem(bi)

                if t.busy {
                    let busy = NSMenuItem(title: "Gravando no mouse…", action: nil, keyEquivalent: "")
                    busy.isEnabled = false
                    menu.addItem(busy)
                }
                if let p = t.profile {
                    profileItems(t, p).forEach(menu.addItem)
                }
                if let msg = t.lastAction {
                    let warn = NSMenuItem(title: msg, action: nil, keyEquivalent: "")
                    warn.image = Self.symbol("exclamationmark.triangle", "Aviso")
                    warn.isEnabled = false
                    menu.addItem(warn)
                }
            }
        }

        menu.addItem(.separator())

        let percent = NSMenuItem(title: "Mostrar porcentagem", action: #selector(togglePercent(_:)), keyEquivalent: "")
        percent.target = self
        percent.state = showPercent ? .on : .off
        menu.addItem(percent)

        let rescan = NSMenuItem(title: "Re-escanear / atualizar bateria",
                                action: #selector(rescan(_:)), keyEquivalent: "r")
        rescan.target = self
        menu.addItem(rescan)

        let quit = NSMenuItem(title: "Sair", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    // MARK: Perfil (DPI, polling, luz)

    private final class ProfileAction: NSObject {
        let target: MouseTarget
        let change: HidppClient.ProfileChange
        init(_ t: MouseTarget, _ c: HidppClient.ProfileChange) { target = t; change = c }
    }

    private static let colors: [(String, UInt8, UInt8, UInt8)] = [
        ("Branco", 0xff, 0xff, 0xff), ("Vermelho", 0xff, 0x00, 0x00), ("Laranja", 0xff, 0x80, 0x00),
        ("Amarelo", 0xff, 0xff, 0x00), ("Verde", 0x00, 0xff, 0x00), ("Ciano", 0x00, 0xff, 0xff),
        ("Azul", 0x00, 0x00, 0xff), ("Roxo", 0x80, 0x00, 0xff), ("Rosa", 0xff, 0x00, 0xff),
    ]

    private static func swatch(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func changeItem(_ title: String, _ t: MouseTarget, _ c: HidppClient.ProfileChange, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(applyChange(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = ProfileAction(t, c)
        i.state = on ? .on : .off
        i.isEnabled = !t.busy
        return i
    }

    private func submenu(_ title: String, _ symbol: String, _ m: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.image = Self.symbol(symbol, title)
        i.submenu = m
        return i
    }

    private func profileItems(_ t: MouseTarget, _ p: HidppClient.OnboardProfile) -> [NSMenuItem] {
        let levels = p.dpis.filter { $0 > 0 }
        let dpi = NSMenu()
        for (i, v) in levels.enumerated() {
            dpi.addItem(changeItem("\(v) DPI", t, .dpiDefault(i), on: i == p.defaultDpiIndex))
        }
        dpi.addItem(.separator())
        let edit = NSMenuItem(title: "Editar níveis…", action: #selector(editDpi(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = t
        edit.isEnabled = !t.busy
        dpi.addItem(edit)

        let rate = NSMenu()
        for ms in t.reportRates.sorted(by: >) {
            rate.addItem(changeItem("\(1000 / ms) Hz", t, .rate(ms: ms), on: ms == p.reportRateMs))
        }

        let cur = HidppClient.LedEffect(profileBytes: p.leds[0])
        var color: (UInt8, UInt8, UInt8)?
        var breath = (periodMs: 4000, intensity: 100)
        var cycle = (periodMs: 8000, intensity: 100)
        var ledName = "Personalizada"
        switch cur {
        case .off?: ledName = "Desligada"
        case let .fixed(r, g, b)?: color = (r, g, b); ledName = "Fixa"
        case let .breathe(r, g, b, pm, i)?: color = (r, g, b); breath = (pm, i); ledName = "Respiração"
        case let .cycle(pm, i)?: cycle = (pm, i); ledName = "Ciclo de cores"
        case nil: break
        }
        let base = color ?? (0xff, 0xff, 0xff)
        let led = NSMenu()
        led.addItem(changeItem("Desligada", t, .led(.off), on: ledName == "Desligada"))
        led.addItem(changeItem("Ciclo de cores", t, .led(.cycle(periodMs: cycle.periodMs, intensity: cycle.intensity)),
                               on: ledName == "Ciclo de cores"))
        led.addItem(changeItem("Respiração", t, .led(.breathe(base.0, base.1, base.2, periodMs: breath.periodMs,
                                                              intensity: breath.intensity)), on: ledName == "Respiração"))
        led.addItem(.separator())
        for (name, r, g, b) in Self.colors {
            let e: HidppClient.LedEffect = ledName == "Respiração"
                ? .breathe(r, g, b, periodMs: breath.periodMs, intensity: breath.intensity) : .fixed(r, g, b)
            let i = changeItem(name, t, .led(e), on: color.map { $0 == (r, g, b) } ?? false)
            i.image = Self.swatch(r, g, b)
            led.addItem(i)
        }

        let current = levels.indices.contains(p.defaultDpiIndex) ? "\(levels[p.defaultDpiIndex]) DPI" : "?"
        return [
            submenu("DPI: \(current)", "cursorarrow.motionlines", dpi),
            submenu("Polling: \(1000 / max(1, p.reportRateMs)) Hz", "speedometer", rate),
            submenu("Luz: \(ledName)", "lightbulb", led),
        ]
    }

    // MARK: Ações

    @objc private func applyChange(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? ProfileAction else { return }
        DeviceEngine.shared.apply(a.change, to: a.target)
    }

    @objc private func editDpi(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? MouseTarget, let p = t.profile else { return }
        let levels = p.dpis.filter { $0 > 0 }
        let alert = NSAlert()
        alert.messageText = "Níveis de DPI"
        alert.informativeText = "Até 5 valores separados por vírgula."
        let field = NSTextField(string: levels.map(String.init).joined(separator: ", "))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Gravar")
        alert.addButton(withTitle: "Cancelar")
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard !new.isEmpty else { return }
        let current = levels.indices.contains(p.defaultDpiIndex) ? levels[p.defaultDpiIndex] : nil
        let def = current.flatMap { new.firstIndex(of: $0) } ?? new.count - 1
        DeviceEngine.shared.apply(.dpi(levels: new, defaultIndex: def), to: t)
    }

    @objc private func togglePercent(_ sender: Any) {
        showPercent.toggle()
        rebuild()
    }

    @objc private func rescan(_ sender: Any) {
        DeviceEngine.shared.rescan()
        DeviceEngine.shared.refreshAllBatteries(profiles: true)
    }

    @objc private func quit(_ sender: Any) {
        NSApp.terminate(sender)
    }
}
