import AppKit

/// Menu-bar status item. Click toggles recording; menu on right-click / long press.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private var stateLabel: NSMenuItem!
    private var transcriptionLabel: NSMenuItem!
    private var toggleItem: NSMenuItem!

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowPanel: (() -> Void)?

    init(existingItem: NSStatusItem) {
        self.statusItem = existingItem
        super.init()
        existingItem.isVisible = true

        // Prefer button action over `item.menu` — assigning a menu immediately
        // after creation has been flaky with Control Center hosting on macOS 26.
        if let button = existingItem.button {
            button.title = "Quill"
            button.image = nil
            button.imagePosition = .noImage
            button.toolTip = "Quill — click to start/stop recording"
            button.setAccessibilityTitle("Quill")
            button.target = self
            button.action = #selector(primaryClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Attach menu after a beat so the extra is already hosted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.statusItem.menu = self.buildMenu()
            // Keep left-click as action: clear menu default left-click behavior
            // by using a custom click handler via button only — menu still
            // opens via right-click / ctrl-click through AppKit defaults when menu set.
            // Actually once menu is set, left click opens menu. That's fine UX.
            self.statusItem.button?.toolTip = "Quill — meeting recorder"
        }
    }

    func install() {
        statusItem.isVisible = true
    }

    func update(recording: Bool, elapsed: String?) {
        stateLabel?.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem?.title = recording ? "Stop recording" : "Start recording"
        statusItem.button?.title = recording ? "●Rec" : "Quill"
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.isVisible = true
    }

    func updateTranscription(_ text: String?) {
        transcriptionLabel?.title = text ?? ""
        transcriptionLabel?.isHidden = text == nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let state = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        stateLabel = state

        let transcription = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcription.isEnabled = false
        transcription.isHidden = true
        menu.addItem(transcription)
        transcriptionLabel = transcription

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        let showPanel = NSMenuItem(
            title: "Show control window",
            action: #selector(showPanelClicked),
            keyEquivalent: "w"
        )
        showPanel.target = self
        menu.addItem(showPanel)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func primaryClicked() {
        // If menu is attached, AppKit usually opens it on left click;
        // this is a fallback when menu isn't set yet.
        if statusItem.menu == nil {
            onToggle?()
        }
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func showPanelClicked() { onShowPanel?() }
}
