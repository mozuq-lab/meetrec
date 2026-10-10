import AVFoundation
import CoreGraphics
import ScreenCaptureKit

public enum Permission: Sendable {
    case screenRecording
    case microphone
}

public enum Permissions {
    public static let screenRecordingSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    public static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// 不足している権限を返す。未確認の権限はここでシステムの許可ダイアログを出す。
    /// - Parameter onMicrophonePrompt: マイクの許可ダイアログを出す直前に呼ばれる
    @MainActor
    public static func missing(onMicrophonePrompt: () -> Void = {}) async -> [Permission] {
        var missing: [Permission] = []

        if !CGPreflightScreenCaptureAccess() {
            // 初回はシステムのダイアログが表示される（許可は「システム設定」で行う）
            if !CGRequestScreenCaptureAccess() {
                missing.append(.screenRecording)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            onMicrophonePrompt()
            if !(await AVCaptureDevice.requestAccess(for: .audio)) {
                missing.append(.microphone)
            }
        default:
            missing.append(.microphone)
        }

        return missing
    }

    /// SCStream / SCShareableContent が権限不足で失敗したかどうか
    public static func isDeniedError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain
            && error.code == SCStreamError.Code.userDeclined.rawValue
    }
}
