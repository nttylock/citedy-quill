import AppKit

/// Always-available fallback UI when the menu-bar status item is hidden
/// (notch overflow / Control Center BentoBox / empty template icon).
/// Small utility panel — not a full app window.
@MainActor
final class ControlPanel: NSObject {
    private let panel: NSPanel
    private let statusField: NSTextField
    private let toggleButton: NSButton

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusField = NSTextField(labelWithString: "idle")
        statusField.font = .systemFont(ofSize: 12, weight: .medium)
        statusField.alignment = .center
        statusField.lineBreakMode = .byTruncatingTail

        toggleButton = NSButton(
            title: "Start recording",
            target: nil,
            action: nil
        )
        toggleButton.bezelStyle = .rounded
        toggleButton.keyEquivalent = "r"

        let openButton = NSButton(title: "Open folder", target: nil, action: nil)
        openButton.bezelStyle = .rounded

        let quitButton = NSButton(title: "Quit", target: nil, action: nil)
        quitButton.bezelStyle = .rounded

        let stack = NSStackView(views: [statusField, toggleButton, openButton, quitButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quill"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            panel.contentView!.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        super.init()

        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        openButton.target = self
        openButton.action = #selector(openClicked)
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        // Closing the panel just hides it — daemon keeps running.
        panel.standardWindowButton(.closeButton)?.target = self
        panel.standardWindowButton(.closeButton)?.action = #selector(hideClicked)
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(recording: Bool, elapsed: String?, transcription: String? = nil) {
        if recording {
            statusField.stringValue = "● recording · \(elapsed ?? "0:00")"
            toggleButton.title = "Stop recording"
        } else if let transcription, !transcription.isEmpty {
            statusField.stringValue = transcription
            toggleButton.title = "Start recording"
        } else {
            statusField.stringValue = "idle"
            toggleButton.title = "Start recording"
        }
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func hideClicked() { panel.orderOut(nil) }
}
