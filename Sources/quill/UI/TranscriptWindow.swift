import AppKit

/// Result window shown after Stop: loader → transcript + LLM summary,
/// with copy / email actions. No osascript, no external .md open.
@MainActor
final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    enum Phase {
        case loading(String)
        case ready
        case failed(String)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let transcriptView = NSTextView()
    private let summaryView = NSTextView()
    private let copyButton = NSButton()
    private let emailButton = NSButton()
    private let openFolderButton = NSButton()

    private var sessionDir: URL?
    private var plainText: String = ""
    private var displayTitle: String = "Transcript"

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    // MARK: - public API

    func presentLoading(sessionName: String, sessionDir: URL) {
        self.sessionDir = sessionDir
        self.displayTitle = sessionName
        self.plainText = ""
        titleLabel.stringValue = sessionName
        window?.title = "Quill — \(sessionName)"
        setPhase(.loading("Транскрибация…"))
        transcriptView.string = ""
        summaryView.string = ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentTranscript(sessionName: String, sessionDir: URL, plainText: String, markdown: String) {
        self.sessionDir = sessionDir
        self.displayTitle = sessionName
        self.plainText = plainText
        titleLabel.stringValue = sessionName
        window?.title = "Quill — \(sessionName)"
        transcriptView.string = plainText.isEmpty ? "(пусто)" : plainText
        summaryView.string = "Суммаризация…"
        setPhase(.loading("Суммаризация (gpt-4o-mini)…"))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentSummary(_ summary: TranscriptSummary) {
        var block = "ИТОГ\n\(summary.summary)\n"
        if !summary.keyPoints.isEmpty {
            block += "\nКЛЮЧЕВОЕ\n"
            for (i, p) in summary.keyPoints.enumerated() {
                block += "\(i + 1). \(p)\n"
            }
        }
        summaryView.string = block.trimmingCharacters(in: .whitespacesAndNewlines)
        setPhase(.ready)

        // Persist next to audio for later.
        if let dir = sessionDir {
            let md = """
            # \(displayTitle) — summary

            ## Итог
            \(summary.summary)

            ## Ключевое
            \(summary.keyPoints.map { "- \($0)" }.joined(separator: "\n"))
            """
            try? Data(md.utf8).write(
                to: dir.appendingPathComponent("summary.md"),
                options: .atomic
            )
        }
    }

    func presentFailure(_ message: String) {
        setPhase(.failed(message))
        if transcriptView.string.isEmpty {
            transcriptView.string = message
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Transcript is already usable; only summary failed.
    func presentSummaryError(_ message: String) {
        summaryView.string = "Саммари недоступно:\n\(message)"
        setPhase(.ready)
        statusLabel.stringValue = "Транскрипт готов · саммари ошибка"
        statusLabel.textColor = .systemOrange
    }

    func updateLoadingStatus(_ text: String) {
        setPhase(.loading(text))
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy"
        )
        copyButton.imagePosition = .imageOnly
        copyButton.bezelStyle = .flexiblePush
        copyButton.toolTip = "Скопировать весь текст"
        copyButton.target = self
        copyButton.action = #selector(copyAll)

        emailButton.image = NSImage(
            systemSymbolName: "envelope",
            accessibilityDescription: "Email"
        )
        emailButton.imagePosition = .imageOnly
        emailButton.bezelStyle = .flexiblePush
        emailButton.toolTip = "Отправить в Mail"
        emailButton.target = self
        emailButton.action = #selector(emailAll)

        openFolderButton.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: "Folder"
        )
        openFolderButton.imagePosition = .imageOnly
        openFolderButton.bezelStyle = .flexiblePush
        openFolderButton.toolTip = "Открыть папку записи"
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolder)

        configureTextView(transcriptView)
        configureTextView(summaryView)
        summaryView.font = .systemFont(ofSize: 13, weight: .medium)

        let transcriptScroll = wrapScroll(transcriptView)
        let summaryScroll = wrapScroll(summaryView)

        let transcriptHeader = sectionLabel("Транскрипт")
        let summaryHeader = sectionLabel("Саммари")

        let toolbar = NSStackView(views: [statusLabel, spinner, NSView(), copyButton, emailButton, openFolderButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [
            titleLabel,
            toolbar,
            summaryHeader,
            summaryScroll,
            transcriptHeader,
            transcriptScroll,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            titleLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            summaryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            summaryScroll.heightAnchor.constraint(equalTo: transcriptScroll.heightAnchor, multiplier: 0.45),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            summaryScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            transcriptScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            copyButton.widthAnchor.constraint(equalToConstant: 32),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
            emailButton.widthAnchor.constraint(equalToConstant: 32),
            emailButton.heightAnchor.constraint(equalToConstant: 28),
            openFolderButton.widthAnchor.constraint(equalToConstant: 32),
            openFolderButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func configureTextView(_ tv: NSTextView) {
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.drawsBackground = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func wrapScroll(_ tv: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.documentView = tv
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    private func setPhase(_ phase: Phase) {
        switch phase {
        case .loading(let msg):
            statusLabel.stringValue = msg
            statusLabel.textColor = .secondaryLabelColor
            spinner.startAnimation(nil)
            copyButton.isEnabled = !plainText.isEmpty
            emailButton.isEnabled = !plainText.isEmpty
        case .ready:
            statusLabel.stringValue = "Готово"
            statusLabel.textColor = .secondaryLabelColor
            spinner.stopAnimation(nil)
            copyButton.isEnabled = true
            emailButton.isEnabled = true
        case .failed(let msg):
            statusLabel.stringValue = msg
            statusLabel.textColor = .systemRed
            spinner.stopAnimation(nil)
            copyButton.isEnabled = !plainText.isEmpty
            emailButton.isEnabled = !plainText.isEmpty
        }
    }

    // MARK: - actions

    @objc private func copyAll() {
        let text = composedShareText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "Скопировано"
        statusLabel.textColor = .systemGreen
    }

    @objc private func emailAll() {
        let text = composedShareText()
        guard !text.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "mailto"
        // Empty recipient — user picks contacts in Mail.
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Quill: \(displayTitle)"),
            URLQueryItem(name: "body", value: text),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
            statusLabel.stringValue = "Открыт Mail"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            // Fallback: copy and notify.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusLabel.stringValue = "mailto не собрался — текст в буфере"
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func openFolder() {
        if let dir = sessionDir {
            NSWorkspace.shared.open(dir)
        }
    }

    private func composedShareText() -> String {
        var parts: [String] = []
        let summary = summaryView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, summary != "Суммаризация…", !summary.hasPrefix("(") {
            parts.append(summary)
            parts.append("")
        }
        let body = plainText.isEmpty
            ? transcriptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            : plainText
        if !body.isEmpty {
            parts.append("ТРАНСКРИПТ")
            parts.append(body)
        }
        return parts.joined(separator: "\n")
    }
}
