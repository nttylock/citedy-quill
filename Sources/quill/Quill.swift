import AppKit
import ArgumentParser
import Foundation

/// Cross-process commands (CLI → running daemon) via DistributedNotificationCenter.
enum QuillIPC {
    static let notificationName = Notification.Name("com.digimata.quill.command")

    enum Command: String {
        case start
        case stop
        case toggle
        case status
        case show
        case quit
    }

    static func post(_ command: Command) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: command.rawValue,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

/// Custom entry point so GUI mode uses a real NSApplicationDelegate
/// (status item must be created in applicationDidFinishLaunching).
@main
enum QuillMain {
    static func main() {
        // Non-daemon subcommands parse & exit without starting AppKit's run loop.
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, !first.hasPrefix("-") {
            switch first {
            case "doctor", "install", "rec", "stop", "status", "show", "quit-daemon", "help":
                Quill.main()
                return
            case "run":
                break
            default:
                // Unknown token — let ArgumentParser print usage / error.
                Quill.main()
                return
            }
        }

        // Default / `run`: start the accessory app with a proper AppKit lifecycle.
        // Doctor checks run AFTER the status item is up (see AppDelegate) so
        // FluidAudio / AVFoundation probes cannot poison menu-bar layout.
        let root: URL = {
            if let idx = args.firstIndex(of: "--out"), args.index(after: idx) < args.endIndex {
                let raw = args[args.index(after: idx)]
                return URL(
                    fileURLWithPath: (raw as NSString).expandingTildeInPath,
                    isDirectory: true
                )
            }
            return Config.resolveRoot(cliOverride: nil)
        }()

        let app = NSApplication.shared
        let delegate = QuillAppDelegate(root: root)
        app.delegate = delegate
        // Accessory = menu bar only, no Dock icon.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// ArgumentParser surface for non-daemon commands (and `quill help`).
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber.",
        subcommands: [
            Run.self, Doctor.self, Install.self,
            Rec.self, Stop.self, Status.self, Show.self, QuitDaemon.self,
        ],
        defaultSubcommand: Run.self
    )
}

/// Kept for `quill help run` / ArgumentParser completeness. Real GUI path is QuillMain.
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // If someone invokes via ArgumentParser path, re-exec through AppKit lifecycle.
        FileHandle.standardError.write(Data(
            "starting quill daemon…\n".utf8
        ))
        // Replace process image with ourselves without subcommand so QuillMain takes GUI path.
        let bin = CommandLine.arguments[0]
        var argv = [bin]
        if let out {
            argv += ["--out", out]
        }
        let cArgs = argv.map { strdup($0) } + [nil]
        execv(bin, cArgs)
        // If exec fails, fall through with a clear error.
        throw ExitCode(1)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Rec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rec",
        abstract: "Start recording (requires a running `quill` daemon)."
    )
    func run() throws {
        try requireDaemon()
        QuillIPC.post(.start)
        print("sent: start recording")
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop recording and transcribe (requires a running daemon)."
    )
    func run() throws {
        try requireDaemon()
        QuillIPC.post(.stop)
        print("sent: stop recording")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether the quill daemon is running."
    )
    func run() {
        if let pid = daemonPID() {
            print("quill daemon running (pid \(pid))")
            print("commands: quill rec | quill stop | quill show | quill quit-daemon")
        } else {
            print("quill daemon not running — start with: quill")
        }
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the floating control window."
    )
    func run() throws {
        try requireDaemon()
        QuillIPC.post(.show)
        print("sent: show control window")
    }
}

struct QuitDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quit-daemon",
        abstract: "Quit the running quill daemon."
    )
    func run() throws {
        try requireDaemon()
        QuillIPC.post(.quit)
        print("sent: quit")
    }
}

private func daemonPID() -> Int32? {
    let selfPid = ProcessInfo.processInfo.processIdentifier
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "quill"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(whereSeparator: \.isNewline) {
        if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != selfPid {
            return pid
        }
    }
    return nil
}

private func requireDaemon() throws {
    guard daemonPID() != nil else {
        FileHandle.standardError.write(Data("quill daemon not running — start with: quill\n".utf8))
        throw ExitCode(1)
    }
}

// MARK: - AppKit lifecycle

@MainActor
final class QuillAppDelegate: NSObject, NSApplicationDelegate {
    private let root: URL
    private var controller: AppController?
    /// Strong ref — status item dies if nothing retains it.
    private var statusItem: NSStatusItem?
    private var menuBar: MenuBarController?

    init(root: URL) {
        self.root = root
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Bare status item first (identical to known-good StatusTest.app).
        // Delay ALL other work until Control Center has hosted the item
        // (non-zero window height). Creating windows/tasks too early leaves
        // the item invisible on macOS 26.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.button?.title = "Quill"
        self.statusItem = item

        scheduleControllerAttach(item: item, attempt: 0)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            self?.controller?.shutdown()
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            """
            quill up · recordings → \(root.path)
              menu bar: "Quill" on the RIGHT (near Wi‑Fi / clock)
              CLI: quill rec | quill stop | quill show | quill status
              ^C to quit

            """.utf8
        ))
    }

    private func scheduleControllerAttach(item: NSStatusItem, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let frame = item.button?.window?.frame
            let hosted = (frame?.height ?? 0) >= 16 && (frame?.minY ?? 0) > 100
            let line = "status-item attempt=\(attempt) frame=\(String(describing: frame)) hosted=\(hosted)\n"
            FileHandle.standardError.write(Data(line.utf8))
            try? line.write(toFile: "/tmp/quill-menubar.txt", atomically: true, encoding: .utf8)

            if !hosted, attempt < 20 {
                // Re-nudge visibility; sometimes Control Center attaches late.
                item.isVisible = true
                self.scheduleControllerAttach(item: item, attempt: attempt + 1)
                return
            }

            let menuBar = MenuBarController(existingItem: item)
            self.menuBar = menuBar
            let controller = AppController(root: self.root, menuBar: menuBar)
            self.controller = controller

            let checks = DoctorReport.run(recordingsRoot: self.root)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks:\n".utf8))
                DoctorReport.print(checks)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // No tiny control panel — reopen shows the result window if any,
        // otherwise the recordings folder.
        controller?.reopenUI()
        return false
    }
}

@MainActor
final class AppController {
    private let root: URL
    private let menuBar: MenuBarController
    /// Lazy: creating an NSWindow during init poisons the menu-bar status item.
    private var transcriptWindow: TranscriptWindowController?
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var ipcObserver: NSObjectProtocol?
    /// Session dir currently shown in the result window (for status matching).
    private var activeResultSession: String?

    private func resultWindow() -> TranscriptWindowController {
        if let transcriptWindow { return transcriptWindow }
        let w = TranscriptWindowController()
        w.onQuit = { [weak self] in self?.shutdown() }
        transcriptWindow = w
        return w
    }

    init(root: URL, menuBar: MenuBarController) {
        self.root = root
        self.menuBar = menuBar
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }

        ipcObserver = DistributedNotificationCenter.default().addObserver(
            forName: QuillIPC.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let cmd = note.object as? String
            Task { @MainActor in
                self?.handleIPC(cmd)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task {
                await self.transcription.setStatusHandler { status in
                    Task { @MainActor [weak self] in
                        self?.handleTranscriptionStatus(status)
                    }
                }
                await self.transcription.resumePending(root: root)
            }
        }
    }

    func reopenUI() {
        // Never dump the user into Finder on reopen — only the result window.
        let win = resultWindow()
        win.showWindow(nil)
        win.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        if let ipcObserver {
            DistributedNotificationCenter.default().removeObserver(ipcObserver)
            self.ipcObserver = nil
        }
        stopSession()
        NSApp.terminate(nil)
    }

    private func handleIPC(_ raw: String?) {
        guard let raw, let cmd = QuillIPC.Command(rawValue: raw) else { return }
        switch cmd {
        case .start:
            if session == nil { Task { await self.startSession() } }
        case .stop:
            if session != nil { stopSession() }
        case .toggle:
            toggle()
        case .status:
            let body = session == nil
                ? "idle · \(root.path)"
                : "recording · \(session!.dir.path)"
            FileHandle.standardError.write(Data("status: \(body)\n".utf8))
        case .show:
            reopenUI()
        case .quit:
            shutdown()
        }
    }

    private func toggle() {
        if session == nil {
            Task { await self.startSession() }
        } else {
            stopSession()
        }
    }

    private func startSession() async {
        // Mic: OS remembers after first Allow (same code signature + bundle id).
        let micOK = await Permissions.ensureMicrophone()
        if !micOK {
            resultWindow().presentFailure(
                "Нет доступа к микрофону.\n\nSystem Settings → Privacy & Security → Microphone → включи Quill."
            )
            Permissions.openMicrophonePrivacySettings()
            return
        }

        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            let msg = "\(error)"
            // Common when System Audio was denied or never granted.
            if msg.contains("process tap") || msg.contains("System Audio") || msg.contains("OSStatus") {
                resultWindow().presentFailure(
                    "Нет доступа к system audio.\n\nНажми Allow один раз в диалоге, либо:\nSystem Settings → Privacy & Security → Screen & System Audio Recording → Quill.\n\n\(msg)"
                )
                Permissions.openSystemAudioPrivacySettings()
            } else {
                resultWindow().presentFailure("Не удалось начать запись:\n\(msg)")
            }
            return
        }

        // Menu bar becomes red mic + live timer — no floating control panel.
        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        let name = dir.lastPathComponent
        activeResultSession = name
        // ONLY the result window — never open Finder/folder on stop.
        let win = resultWindow()
        win.presentLoading(sessionName: name, sessionDir: dir)
        win.showWindow(nil)
        win.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func handleTranscriptionStatus(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)

        case .transcribing(let name, let queued):
            let text = queued > 0
                ? "transcribing \(name) · \(queued) queued"
                : "transcribing \(name)"
            menuBar.updateTranscription(text)
            if activeResultSession == name || activeResultSession == nil {
                activeResultSession = name
                resultWindow().updateLoadingStatus(
                    queued > 0
                        ? "Транскрибация… (\(queued) в очереди)"
                        : "Транскрибация…"
                )
            }

        case .completed(let name, let dir, let plainText, let markdown):
            menuBar.updateTranscription(nil)
            activeResultSession = name
            resultWindow().presentTranscript(
                sessionName: name,
                sessionDir: dir,
                plainText: plainText,
                markdown: markdown
            )
            Task { await self.runSummary(sessionName: name, sessionDir: dir, plainText: plainText) }

        case .failed(let name, let message):
            let text = "transcription failed · \(name)"
            menuBar.updateTranscription(text)
            if activeResultSession == name || activeResultSession == nil {
                resultWindow().presentFailure("Ошибка транскрипции:\n\(message)")
            }
        }
    }

    private func runSummary(sessionName: String, sessionDir: URL, plainText: String) async {
        let win = resultWindow()
        guard let apiKey = Config.openAIAPIKey() else {
            win.presentSummaryError("Нет OpenAI API key")
            return
        }
        win.updateLoadingStatus("Суммаризация (gpt-4o-mini)…")
        do {
            let summary = try await SummaryService.summarize(
                transcript: plainText,
                language: Config.transcriptionLanguage(),
                apiKey: apiKey,
                baseURL: Config.transcriptionBaseURL()
            )
            if activeResultSession == sessionName {
                win.presentSummary(summary)
            }
            FileHandle.standardError.write(Data(
                "summary ready · \(sessionDir.lastPathComponent)\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data("summary failed: \(error)\n".utf8))
            if activeResultSession == sessionName {
                win.presentSummaryError("\(error)")
            }
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        menuBar.update(recording: true, elapsed: elapsed)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
