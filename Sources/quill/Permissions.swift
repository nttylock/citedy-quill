import AppKit
import AVFoundation
import Foundation

/// One-shot TCC requests. After the user clicks Allow, macOS stores the grant
/// against the app's code signature + bundle id — we must not re-prompt in app
/// code, and we must keep signing identity stable (see package-app.sh).
enum Permissions {
    /// Mic: returns true if authorized (prompts only when status is notDetermined).
    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Open System Settings → Privacy for Screen & System Audio Recording.
    /// System-audio TCC is granted by the OS dialog on first process-tap; after
    /// that it lives in Settings. There is no public "isAuthorized" API.
    static func openSystemAudioPrivacySettings() {
        // Sequoia / Tahoe deep link for Screen & System Audio Recording.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophonePrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
