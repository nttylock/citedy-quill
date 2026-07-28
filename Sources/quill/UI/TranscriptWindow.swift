import AppKit
import AVFoundation

/// Result window after Stop: loader → summary/transcript + actions:
/// Protocol · Speak (Cartesia) · Share (Copy / Mail / Telegram / WhatsApp)
@MainActor
final class TranscriptWindowController: NSWindowController, NSWindowDelegate, AVAudioPlayerDelegate {
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

    // Top utility
    private let copyButton = NSButton()
    private let openFolderButton = NSButton()
    private let quitButton = NSButton()
    private let quitLabeledButton = NSButton()

    // Action bar (slice)
    private let protocolButton = NSButton()
    private let speakButton = NSButton()
    private let shareButton = NSButton()

    /// App quit (wired from AppController).
    var onQuit: (() -> Void)?

    private var sessionDir: URL?
    private var plainText: String = ""
    private var summaryPlain: String = ""
    private var displayTitle: String = "Transcript"
    private var isBusy = false

    private var audioPlayer: AVAudioPlayer?
    private var audioFileURL: URL?
    private var isSpeaking = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    // MARK: - public API

    func presentLoading(sessionName: String, sessionDir: URL) {
        resetSession(name: sessionName, dir: sessionDir)
        setPhase(.loading("Транскрибация…"))
        transcriptView.string = ""
        summaryView.string = ""
        setActionsEnabled(false)
        showFront()
    }

    func presentTranscript(sessionName: String, sessionDir: URL, plainText: String, markdown: String) {
        _ = markdown
        self.sessionDir = sessionDir
        self.displayTitle = sessionName
        self.plainText = plainText
        titleLabel.stringValue = sessionName
        window?.title = "Quill — \(sessionName)"
        transcriptView.string = plainText.isEmpty ? "(пусто)" : plainText
        summaryView.string = "Суммаризация…"
        setPhase(.loading("Суммаризация (gpt-4o-mini)…"))
        setActionsEnabled(false)
        showFront()
    }

    func presentSummary(_ summary: TranscriptSummary) {
        var block = "ИТОГ\n\(summary.summary)\n"
        if !summary.keyPoints.isEmpty {
            block += "\nКЛЮЧЕВОЕ\n"
            for (i, p) in summary.keyPoints.enumerated() {
                block += "\(i + 1). \(p)\n"
            }
        }
        summaryPlain = block.trimmingCharacters(in: .whitespacesAndNewlines)
        summaryView.string = summaryPlain
        setPhase(.ready)
        setActionsEnabled(true)

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
        setActionsEnabled(!plainText.isEmpty)
        showFront()
    }

    func presentSummaryError(_ message: String) {
        summaryView.string = "Саммари недоступно:\n\(message)"
        summaryPlain = ""
        setPhase(.ready)
        statusLabel.stringValue = "Транскрипт готов · саммари ошибка"
        statusLabel.textColor = .systemOrange
        // Protocol can still run from transcript; speak needs summary text → use transcript slice
        setActionsEnabled(!plainText.isEmpty)
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

        styleIconButton(copyButton, symbol: "doc.on.doc", tooltip: "Скопировать", action: #selector(copyAll))
        styleIconButton(openFolderButton, symbol: "folder", tooltip: "Папка записи", action: #selector(openFolder))
        styleIconButton(quitButton, symbol: "xmark.circle.fill", tooltip: "Выйти из Quill", action: #selector(quitApp))

        styleTextButton(protocolButton, title: "Протокол", symbol: "doc.plaintext", action: #selector(runProtocol))
        styleTextButton(speakButton, title: "Озвучить", symbol: "speaker.wave.2", action: #selector(toggleSpeak))
        styleTextButton(shareButton, title: "Поделиться", symbol: "square.and.arrow.up", action: #selector(shareMenu))
        // Explicit labeled quit — not just a tiny power icon.
        styleTextButton(quitLabeledButton, title: "Выйти", symbol: "xmark.circle", action: #selector(quitApp))

        configureTextView(transcriptView)
        configureTextView(summaryView)
        summaryView.font = .systemFont(ofSize: 13, weight: .medium)

        let transcriptScroll = wrapScroll(transcriptView)
        let summaryScroll = wrapScroll(summaryView)

        let topBar = NSStackView(views: [
            statusLabel, spinner, NSView(), copyButton, openFolderButton, quitButton,
        ])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionBar = NSStackView(views: [
            protocolButton, speakButton, shareButton, NSView(), quitLabeledButton,
        ])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 10
        actionBar.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let root = NSStackView(views: [
            titleLabel,
            topBar,
            actionBar,
            sectionLabel("Саммари"),
            summaryScroll,
            sectionLabel("Транскрипт"),
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
            topBar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            actionBar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            titleLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            summaryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            summaryScroll.heightAnchor.constraint(equalTo: transcriptScroll.heightAnchor, multiplier: 0.5),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            summaryScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            transcriptScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            copyButton.widthAnchor.constraint(equalToConstant: 32),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
            openFolderButton.widthAnchor.constraint(equalToConstant: 32),
            openFolderButton.heightAnchor.constraint(equalToConstant: 28),
            quitButton.widthAnchor.constraint(equalToConstant: 32),
            quitButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func styleIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .flexiblePush
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    private func styleTextButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
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
            isBusy = true
        case .ready:
            statusLabel.stringValue = "Готово"
            statusLabel.textColor = .secondaryLabelColor
            spinner.stopAnimation(nil)
            isBusy = false
        case .failed(let msg):
            statusLabel.stringValue = msg
            statusLabel.textColor = .systemRed
            spinner.stopAnimation(nil)
            isBusy = false
        }
    }

    private func setActionsEnabled(_ enabled: Bool) {
        let on = enabled && !isBusy
        protocolButton.isEnabled = on && !plainText.isEmpty
        speakButton.isEnabled = on && speakableText() != nil
        shareButton.isEnabled = on && !shareText().isEmpty
        copyButton.isEnabled = !plainText.isEmpty || !summaryPlain.isEmpty
    }

    private func resetSession(name: String, dir: URL) {
        stopAudio()
        sessionDir = dir
        displayTitle = name
        plainText = ""
        summaryPlain = ""
        audioFileURL = nil
        titleLabel.stringValue = name
        window?.title = "Quill — \(name)"
        speakButton.title = "Озвучить"
    }

    private func showFront() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - actions

    @objc private func copyAll() {
        let text = shareText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashStatus("Скопировано", .systemGreen)
    }

    @objc private func openFolder() {
        if let dir = sessionDir {
            NSWorkspace.shared.open(dir)
        }
    }

    @objc private func quitApp() {
        onQuit?()
    }

    @objc private func runProtocol() {
        guard !isBusy, !plainText.isEmpty else { return }
        guard let apiKey = Config.openAIAPIKey() else {
            flashStatus("Нет OPENAI_API_KEY", .systemRed)
            return
        }
        setPhase(.loading("Протокол (gpt-4o-mini)…"))
        setActionsEnabled(false)

        Task {
            do {
                let proto = try await SummaryService.generateProtocol(
                    transcript: plainText,
                    language: Config.transcriptionLanguage(),
                    apiKey: apiKey,
                    baseURL: Config.transcriptionBaseURL()
                )
                await MainActor.run {
                    // Show protocol in summary pane (primary deliverable).
                    summaryPlain = proto
                    summaryView.string = proto
                    if let dir = self.sessionDir {
                        try? Data(proto.utf8).write(
                            to: dir.appendingPathComponent("protocol.md"),
                            options: .atomic
                        )
                    }
                    // Invalidate old audio — text changed.
                    self.audioFileURL = nil
                    self.stopAudio()
                    self.setPhase(.ready)
                    self.setActionsEnabled(true)
                    self.flashStatus("Протокол готов", .systemGreen)
                }
            } catch {
                await MainActor.run {
                    self.setPhase(.ready)
                    self.setActionsEnabled(true)
                    self.flashStatus("Протокол: \(error)", .systemRed)
                }
            }
        }
    }

    @objc private func toggleSpeak() {
        if isSpeaking {
            stopAudio()
            flashStatus("Остановлено", .secondaryLabelColor)
            return
        }
        // If audio already generated → play. Else synthesize then play.
        if let url = resolvedAudioURL() {
            play(url: url)
            return
        }
        generateAudioAndPlay()
    }

    /// Ensure summary.mp3 exists (Cartesia), then play.
    private func generateAudioAndPlay() {
        guard !isBusy else { return }
        guard let text = speakableText() else {
            flashStatus("Нечего озвучивать — дождись саммари или сделай протокол", .systemOrange)
            return
        }
        guard let apiKey = Config.cartesiaAPIKey() else {
            flashStatus("Нет CARTESIA_API_KEY в ~/.config/quill/env", .systemRed)
            return
        }

        setPhase(.loading("Озвучка (Cartesia)…"))
        setActionsEnabled(false)

        let voice = Config.cartesiaVoiceId()
        let model = Config.cartesiaModelId()
        let lang = Config.transcriptionLanguage()

        Task {
            do {
                let mp3 = try await CartesiaService.synthesizeMP3(
                    text: text,
                    language: lang,
                    apiKey: apiKey,
                    voiceId: voice,
                    modelId: model
                )
                let url: URL
                if let dir = self.sessionDir {
                    url = dir.appendingPathComponent("summary.mp3")
                    try mp3.write(to: url, options: .atomic)
                } else {
                    url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("quill-summary-\(UUID().uuidString).mp3")
                    try mp3.write(to: url, options: .atomic)
                }
                await MainActor.run {
                    self.audioFileURL = url
                    self.setPhase(.ready)
                    self.setActionsEnabled(true)
                    self.play(url: url)
                }
            } catch {
                await MainActor.run {
                    self.setPhase(.ready)
                    self.setActionsEnabled(true)
                    self.flashStatus("TTS: \(error)", .systemRed)
                }
            }
        }
    }

    @objc private func shareMenu(_ sender: NSButton) {
        // Flat menu — no nested submenus (they were easy to miss / grayed out).
        let menu = NSMenu(title: "Share")
        let hasAudio = resolvedAudioURL() != nil

        menu.addItem(menuItem("Скопировать текст", #selector(copyAll)))

        menu.addItem(.separator())

        // Exactly as requested:
        let playTitle = isSpeaking ? "Остановить аудио" : "Запустить аудио"
        menu.addItem(menuItem(playTitle, #selector(audioPlayFromMenu)))
        menu.addItem(menuItem("Перейти к аудио", #selector(audioRevealInFinder)))

        menu.addItem(.separator())

        // Share audio — always enabled; generate on the fly if needed.
        menu.addItem(menuItem("Поделиться аудио → Mail", #selector(shareAudioMail)))
        menu.addItem(menuItem("Поделиться аудио → Telegram", #selector(shareAudioTelegram)))
        menu.addItem(menuItem("Поделиться аудио → WhatsApp", #selector(shareAudioWhatsApp)))

        menu.addItem(.separator())

        menu.addItem(menuItem("Текст → Mail", #selector(shareMailText)))
        menu.addItem(menuItem("Текст → Telegram", #selector(shareTelegramText)))
        menu.addItem(menuItem("Текст → WhatsApp", #selector(shareWhatsAppText)))

        if !hasAudio {
            let hint = NSMenuItem(
                title: "(аудио появится после «Озвучить» или «Запустить»)",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - text share

    @objc private func shareMailText() {
        openShareURL(scheme: "mailto", query: [
            "subject": "Quill: \(displayTitle)",
            "body": shareText(),
        ], emptyPath: true)
    }

    @objc private func shareTelegramText() {
        let text = shareText(max: 3500)
        openShareURL(absolute: "https://t.me/share/url", query: [
            "url": "https://github.com/nttylock/citedy-quill",
            "text": text,
        ])
    }

    @objc private func shareWhatsAppText() {
        let text = shareText(max: 3500)
        openShareURL(absolute: "https://wa.me/", query: [
            "text": text,
        ])
    }

    // MARK: - audio menu actions

    @objc private func audioPlayFromMenu() {
        if isSpeaking {
            stopAudio()
            flashStatus("Остановлено", .secondaryLabelColor)
            return
        }
        if let url = resolvedAudioURL() {
            play(url: url)
        } else {
            // Generate then play.
            generateAudioAndPlay()
        }
    }

    @objc private func audioRevealInFinder() {
        ensureAudioThen { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self.flashStatus("Finder → summary.mp3", .secondaryLabelColor)
        }
    }

    @objc private func shareAudioMail() {
        ensureAudioThen { url in
            if let service = NSSharingService(named: .composeEmail) {
                service.subject = "Quill: \(self.displayTitle)"
                if service.canPerform(withItems: [url]) {
                    service.perform(withItems: [url, self.shareText(max: 2000)])
                    self.flashStatus("Mail…", .secondaryLabelColor)
                    return
                }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                "Аудио: \(url.path)\n\n\(self.shareText(max: 1500))",
                forType: .string
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self.flashStatus("Файл в Finder, путь в буфере — приложи в Mail", .systemOrange)
        }
    }

    @objc private func shareAudioTelegram() {
        ensureAudioThen { url in
            self.shareAudioFile(
                url: url,
                appBundleIds: [
                    "ru.keepcoder.Telegram",
                    "com.tdesktop.Telegram",
                    "org.telegram.desktop",
                ],
                appName: "Telegram"
            )
        }
    }

    @objc private func shareAudioWhatsApp() {
        ensureAudioThen { url in
            self.shareAudioFile(
                url: url,
                appBundleIds: [
                    "net.whatsapp.WhatsApp",
                    "desktop.WhatsApp",
                ],
                appName: "WhatsApp"
            )
        }
    }

    /// If mp3 missing — generate via Cartesia, then run action.
    private func ensureAudioThen(_ action: @escaping (URL) -> Void) {
        if let url = resolvedAudioURL() {
            action(url)
            return
        }
        guard let text = speakableText() else {
            flashStatus("Сначала дождись саммари или нажми Протокол", .systemOrange)
            return
        }
        guard let apiKey = Config.cartesiaAPIKey() else {
            flashStatus("Нет CARTESIA_API_KEY", .systemRed)
            return
        }
        setPhase(.loading("Готовлю аудио…"))
        setActionsEnabled(false)
        let voice = Config.cartesiaVoiceId()
        let model = Config.cartesiaModelId()
        let lang = Config.transcriptionLanguage()
        Task {
            do {
                let mp3 = try await CartesiaService.synthesizeMP3(
                    text: text,
                    language: lang,
                    apiKey: apiKey,
                    voiceId: voice,
                    modelId: model
                )
                let url: URL
                if let dir = self.sessionDir {
                    url = dir.appendingPathComponent("summary.mp3")
                    try mp3.write(to: url, options: .atomic)
                } else {
                    url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("quill-\(UUID().uuidString).mp3")
                    try mp3.write(to: url, options: .atomic)
                }
                await MainActor.run {
                    self.audioFileURL = url
                    self.setPhase(.ready)
                    self.setActionsEnabled(true)
                    action(url)
                }
            } catch {
                await MainActor.run {
                    self.setPhase(.ready)
                    self.setActionsEnabled(true)
                    self.flashStatus("Аудио: \(error)", .systemRed)
                }
            }
        }
    }

    /// Open mp3 with the messenger if installed; else Finder + clipboard path.
    private func shareAudioFile(url: URL, appBundleIds: [String], appName: String) {
        for bid in appBundleIds {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                    Task { @MainActor in
                        if let error {
                            self.fallbackShareAudio(url: url, appName: appName, error: "\(error)")
                        } else {
                            self.flashStatus("Открыто в \(appName)", .secondaryLabelColor)
                        }
                    }
                }
                return
            }
        }
        fallbackShareAudio(url: url, appName: appName, error: nil)
    }

    private func fallbackShareAudio(url: URL, appName: String, error: String?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let hint = error.map { " (\($0))" } ?? ""
        flashStatus(
            "\(appName) не найден\(hint). Файл в Finder, путь скопирован",
            .systemOrange
        )
    }

    private func resolvedAudioURL() -> URL? {
        if let audioFileURL, FileManager.default.fileExists(atPath: audioFileURL.path) {
            return audioFileURL
        }
        if let dir = sessionDir {
            let candidate = dir.appendingPathComponent("summary.mp3")
            if FileManager.default.fileExists(atPath: candidate.path) {
                audioFileURL = candidate
                return candidate
            }
        }
        return nil
    }

    // MARK: - audio playback

    private func play(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isSpeaking = true
            speakButton.title = "Стоп"
            speakButton.image = NSImage(
                systemSymbolName: "stop.fill",
                accessibilityDescription: "Stop"
            )
            flashStatus("Играет…", .secondaryLabelColor)
        } catch {
            flashStatus("Play: \(error)", .systemRed)
        }
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        speakButton.title = "Озвучить"
        speakButton.image = NSImage(
            systemSymbolName: "speaker.wave.2",
            accessibilityDescription: "Speak"
        )
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakButton.title = "Озвучить"
            self.speakButton.image = NSImage(
                systemSymbolName: "speaker.wave.2",
                accessibilityDescription: "Speak"
            )
            self.flashStatus(flag ? "Готово" : "Воспроизведение прервано", .secondaryLabelColor)
        }
    }

    // MARK: - text helpers

    /// Prefer summary/protocol for TTS; fall back to short transcript head.
    /// Always strip markdown / labels so Cartesia does not say "hash hash".
    private func speakableText() -> String? {
        let s = summaryPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if !s.isEmpty, !s.hasPrefix("Саммари недоступно"), s != "Суммаризация…" {
            raw = s
        } else {
            let t = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            raw = t
        }
        let speech = TranscriptCleanup.forSpeech(raw)
        if speech.isEmpty { return nil }
        return String(speech.prefix(2500))
    }

    private func shareText(max: Int? = nil) -> String {
        var parts: [String] = []
        let summary = summaryView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, summary != "Суммаризация…", !summary.hasPrefix("Саммари недоступно") {
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
        var text = parts.joined(separator: "\n")
        if let max, text.count > max {
            text = String(text.prefix(max)) + "\n…"
        }
        return text
    }

    private func openShareURL(scheme: String? = nil, absolute: String? = nil, query: [String: String], emptyPath: Bool = false) {
        var components: URLComponents
        if let absolute, let u = URLComponents(string: absolute) {
            components = u
        } else if let scheme {
            components = URLComponents()
            components.scheme = scheme
            if emptyPath { components.path = "" }
        } else {
            return
        }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let url = components.url {
            NSWorkspace.shared.open(url)
            flashStatus("Открыто", .secondaryLabelColor)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shareText(), forType: .string)
            flashStatus("URL не собрался — текст в буфере", .systemOrange)
        }
    }

    private func flashStatus(_ text: String, _ color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }
}
