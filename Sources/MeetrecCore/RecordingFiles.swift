import Foundation

/// 1 回の録音で作るファイル: <dir>/<yyyyMMdd-HHmmss>_{system,mic,mix}.m4a
public struct RecordingFiles: Sendable {
    public let stamp: String
    public let system: URL
    public let microphone: URL
    /// 2 つを重ねたもの（メニューバー版で作成）
    public let mix: URL

    public init(directory: URL, date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        stamp = formatter.string(from: date)
        system = directory.appendingPathComponent("\(stamp)_system.m4a")
        microphone = directory.appendingPathComponent("\(stamp)_mic.m4a")
        mix = directory.appendingPathComponent("\(stamp)_mix.m4a")
    }

    /// 既に存在するファイル（上書きを避けるため）
    public var existing: [URL] {
        [system, microphone, mix].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct MeetrecError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
