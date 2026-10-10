import AppKit
import MeetrecCore

@MainActor
enum Alerts {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    static func permissionsMissing(_ missing: [Permission]) {
        let needsScreen = missing.contains(.screenRecording)
        var lines = ["MeetRec に次の権限を許可してください。"]
        if needsScreen {
            lines += [
                "",
                "■ 画面収録とシステムオーディオ録音（システム音声の録音に必要）",
                "「システム設定」>「プライバシーとセキュリティ」>「画面収録とシステムオーディオ録音」で MeetRec をオンにし、MeetRec を再起動してください。",
            ]
        }
        if missing.contains(.microphone) {
            lines += [
                "",
                "■ マイク（マイク音声の録音に必要）",
                "「システム設定」>「プライバシーとセキュリティ」>「マイク」で MeetRec をオンにしてください。",
            ]
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "録音に必要な権限がありません"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "システム設定を開く")
        if needsScreen {
            alert.addButton(withTitle: "MeetRec を再起動")
        }
        alert.addButton(withTitle: "閉じる")
        NSApp.activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(needsScreen ? Permissions.screenRecordingSettingsURL : Permissions.microphoneSettingsURL)
        case .alertSecondButtonReturn where needsScreen:
            relaunch()
        default:
            break
        }
    }

    /// 画面収録の権限は再起動後に反映されるため、自分を起動し直す
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "sh", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
