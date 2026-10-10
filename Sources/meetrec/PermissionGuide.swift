import Foundation
import MeetrecCore

/// CLI 用の権限設定の案内。CLI の権限は meetrec を起動したアプリ（ターミナルなど）に付く。
enum PermissionGuide {
    static func text(for missing: [Permission]) -> String {
        let app = hostAppName
        var lines = [
            "録音に必要な権限がありません。次の設定を行ってから、もう一度実行してください。",
            "",
        ]

        if missing.contains(.screenRecording) {
            lines += [
                "■ 画面収録とシステムオーディオ録音（システム音声の録音に必要）",
                "  1. 「システム設定」>「プライバシーとセキュリティ」>「画面収録とシステムオーディオ録音」を開く",
                "  2. 一覧で「\(app)」をオンにする（一覧にない場合は「+」から追加）",
                "  3. 「終了して再度開く」と表示されたら、\(app) を再起動する",
                "  設定画面を開くコマンド:",
                "    open \"\(Permissions.screenRecordingSettingsURL.absoluteString)\"",
                "",
            ]
        }

        if missing.contains(.microphone) {
            lines += [
                "■ マイク（マイク音声の録音に必要）",
                "  1. 「システム設定」>「プライバシーとセキュリティ」>「マイク」を開く",
                "  2. 一覧で「\(app)」をオンにする",
                "  設定画面を開くコマンド:",
                "    open \"\(Permissions.microphoneSettingsURL.absoluteString)\"",
                "",
            ]
        }

        lines.append("※ 権限は meetrec 本体ではなく、meetrec を起動したアプリ（\(app)）に与えられます。")
        return lines.joined(separator: "\n")
    }

    /// 権限の付与先になる「meetrec を起動したアプリ」の表示名
    private static var hostAppName: String {
        let env = ProcessInfo.processInfo.environment
        switch env["TERM_PROGRAM"] {
        case "Apple_Terminal": return "ターミナル"
        case "iTerm.app": return "iTerm"
        case "vscode": return env["__CFBundleIdentifier"] == "com.microsoft.VSCode" ? "Visual Studio Code" : "お使いのエディタ"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        case "WezTerm": return "WezTerm"
        default: return "お使いのターミナルアプリ"
        }
    }
}
