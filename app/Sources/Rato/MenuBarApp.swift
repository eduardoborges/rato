import AppKit
import IOKit.hid
import SwiftUI

/// Barra de menus: o ícone do mouse com a bateria do primeiro mouse, e um painel com bateria, DPI, polling e luz.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var batteryTimer: Timer?
    private let model = PanelModel()
    private let popover = NSPopover()
    /// Prévia: o painel com dados de exemplo, sem abrir nada no HID.
    private let sample: [MouseCard]?
    private var previewAnchor: NSWindow?
    /// Fecha o painel quando o clique vai para outro app. Depois de dias rodando, o .transient às vezes deixa de fechar.
    private var outsideClick: Any?

    init(sample: [MouseCard]? = nil) { self.sample = sample }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        statusItem = item

        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        model.onChange = { [weak self] in self?.rebuild() }
        rebuild()

        if sample != nil {
            // A barra de menus pode esconder um ícone novo. A prévia prende o painel a uma janela invisível no canto da tela.
            let top = NSScreen.main?.visibleFrame ?? .zero
            let anchor = NSWindow(contentRect: NSRect(x: top.minX + 400, y: top.maxY - 1, width: 1, height: 1),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            anchor.backgroundColor = .clear
            anchor.level = .statusBar
            anchor.orderFrontRegardless()
            previewAnchor = anchor
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            if let view = anchor.contentView { popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
            return
        }

        // Num .app, o macOS só mostra o receptor ao IOHIDManager com a permissão de
        // Monitoramento de Entrada. Pelo terminal, o app herda a do terminal.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            hlog("sem permissão de Monitoramento de Entrada; pedindo ao macOS")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let engine = DeviceEngine.shared
        engine.onChanged = { [weak self] in self?.rebuild() }
        engine.start()

        // Enumeração inicial (a thread HID cuida dos callbacks).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = engine.scan(waitSeconds: 2.5)
            DispatchQueue.main.async { self?.rebuild() }
        }

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            // Um mouse que dormia na abertura não respondeu ao handshake. O rescan só sonda de novo quem ficou sem mouse.
            DeviceEngine.shared.rescan()
            DeviceEngine.shared.refreshAllBatteries()
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(sender); return }
        // Um app de barra de menus fica atrás dos outros; sem ativar, o campo de DPI não recebe o teclado.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Sem isso, o primeiro controle abre em foco, com um anel azul em volta.
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        // O monitor global só vê cliques entregues a outros apps; os do ícone e do painel não chegam aqui.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
    }

    // MARK: Ícone

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

    private func rebuild() {
        let mice = sample ?? DeviceEngine.shared.snapshot().map(MouseCard.init)
        model.mice = mice
        guard let button = statusItem?.button else { return }
        // preferência: 1º mouse com % real
        let b = mice.first(where: { $0.battery?.percent != nil })?.battery ?? mice.lazy.compactMap(\.battery).first
        let text = b.map(Self.levelText)
        let icon = Self.mouseIcon(level: b?.percent, charging: b?.charging == true)
        icon.accessibilityDescription = text.map { "Bateria do mouse \($0)" } ?? "Nenhum mouse"
        button.image = icon
        button.title = model.showPercent ? text ?? "" : ""
        button.appearsDisabled = mice.isEmpty
    }
}
