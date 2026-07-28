import AppKit

/// Menu bar for Quill — impossible to miss, one-click stop.
///
/// Idle:      orange badge + text "Quill" → click opens menu (Start / Quit)
/// Recording: red badge + bold "■ STOP 0:29" → **click STOPS immediately**
///            (no menu while recording — stop is the only action)
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var isRecording = false
    private var elapsedText = "0:00"
    private var transcriptionText: String?

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init(existingItem: NSStatusItem) {
        self.statusItem = existingItem
        super.init()
        existingItem.isVisible = true
        existingItem.length = NSStatusItem.variableLength

        menu.delegate = self
        menu.autoenablesItems = false

        if let button = existingItem.button {
            button.wantsLayer = true
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.target = self
        }
        applyAppearance()
    }

    func install() {
        statusItem.isVisible = true
        applyAppearance()
    }

    func update(recording: Bool, elapsed: String?) {
        isRecording = recording
        elapsedText = elapsed ?? "0:00"
        applyAppearance()
    }

    func updateTranscription(_ text: String?) {
        transcriptionText = text
        if !isRecording { applyAppearance() }
    }

    // MARK: - NSMenuDelegate (idle menu only)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(
            title: "Quill · готов",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        if let t = transcriptionText, !t.isEmpty {
            let p = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            p.isEnabled = false
            menu.addItem(p)
        }

        menu.addItem(.separator())

        let start = NSMenuItem(
            title: "Начать запись",
            action: #selector(toggleFromMenu),
            keyEquivalent: "r"
        )
        start.keyEquivalentModifierMask = [.command]
        start.target = self
        start.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        menu.addItem(start)

        menu.addItem(.separator())

        let openFolder = NSMenuItem(
            title: "Открыть папку записей",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        openFolder.keyEquivalentModifierMask = [.command]
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Выйти из Quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        quit.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    // MARK: - appearance

    private func applyAppearance() {
        guard let button = statusItem.button else { return }

        if isRecording {
            // CRITICAL: no menu while recording — left-click must STOP, not open a menu.
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopClicked)
            button.sendAction(on: [.leftMouseUp])

            button.image = Self.badge(symbol: "stop.fill", fill: .systemRed, glyph: 9)
            button.image?.isTemplate = false
            // Explicit "STOP" so it's never mistaken for system mic.
            button.attributedTitle = NSAttributedString(
                string: " STOP \(elapsedText)",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
                ]
            )
            button.toolTip = "НАЖМИ СЮДА чтобы остановить запись"
            button.setAccessibilityLabel("Остановить запись \(elapsedText)")
            button.setAccessibilityHelp("Остановить запись Quill")
            statusItem.length = NSStatusItem.variableLength
        } else {
            // Idle: menu with Start + Quit
            button.action = nil
            statusItem.menu = menu

            button.image = Self.badge(symbol: "mic.fill", fill: .systemOrange, glyph: 10)
            button.image?.isTemplate = false
            // ALWAYS show word "Quill" so it can't blend / be confused with system mic.
            let label = (transcriptionText?.isEmpty == false) ? " Quill…" : " Quill"
            button.attributedTitle = NSAttributedString(
                string: label,
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                ]
            )
            button.toolTip = "Quill — меню: запись / выход"
            button.setAccessibilityLabel("Quill")
            statusItem.length = NSStatusItem.variableLength
        }

        button.appearsDisabled = false
        statusItem.isVisible = true
    }

    private static func badge(symbol: String, fill: NSColor, glyph: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
                return true
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: glyph, weight: .bold)
            let sym = base.withSymbolConfiguration(cfg) ?? base
            sym.isTemplate = true
            let gs = NSSize(width: glyph + 1, height: glyph + 1)
            let tinted = NSImage(size: gs)
            tinted.lockFocus()
            let gr = NSRect(origin: .zero, size: gs)
            sym.draw(in: gr)
            NSColor.white.set()
            gr.fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(
                x: (rect.width - gs.width) / 2,
                y: (rect.height - gs.height) / 2,
                width: gs.width,
                height: gs.height
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - actions

    @objc private func stopClicked() {
        // Direct stop while recording — no menu in the way.
        onToggle?()
    }

    @objc private func toggleFromMenu() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
