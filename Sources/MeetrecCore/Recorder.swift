import AVFoundation
import ScreenCaptureKit

/// SCStream でシステム音声とマイクを取り込み、それぞれの AudioFileWriter に流す。
/// 映像は不要だが、.screen の出力先がないと SCStream がフレーム破棄のログを出し続けるため、
/// 最小解像度・低フレームレートで受け取って捨てる。
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let systemAudio: AudioFileWriter
    let microphone: AudioFileWriter

    private let onUnexpectedStop: @Sendable (Error) -> Void
    private let screenQueue = DispatchQueue(label: "meetrec.screen")
    private var stream: SCStream?

    /// - Parameters:
    ///   - onWarning: 録音中の警告（書き込みエラーなど）。任意のスレッドから呼ばれる
    ///   - onUnexpectedStop: スリープや権限の取り消しなどで録音が止まったとき。任意のスレッドから呼ばれる
    public init(
        files: RecordingFiles,
        onWarning: @escaping @Sendable (String) -> Void,
        onUnexpectedStop: @escaping @Sendable (Error) -> Void
    ) {
        let clock = SharedClock()
        systemAudio = AudioFileWriter(track: .system, url: files.system, clock: clock, warn: onWarning)
        microphone = AudioFileWriter(track: .microphone, url: files.microphone, clock: clock, warn: onWarning)
        self.onUnexpectedStop = onUnexpectedStop
    }

    /// 録音に使われるマイク（システムの既定の入力デバイス）の名前
    public static var microphoneName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw MeetrecError("キャプチャ対象のディスプレイが見つかりません")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        // 映像: 使わないので最小限
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.queueDepth = 3
        config.showsCursor = false
        // システム音声
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // マイク（システムの既定の入力デバイス）
        config.captureMicrophone = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudio.queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphone.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// キャプチャを止め、両ファイルを閉じる（システム音声、マイクの順で返す）
    public func stop() async -> [TrackSummary] {
        if let stream {
            try? await stream.stopCapture()
        }
        async let system = systemAudio.finish()
        async let mic = microphone.finish()
        return await [system, mic]
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            systemAudio.append(sampleBuffer)
        case .microphone:
            microphone.append(sampleBuffer)
        case .screen:
            return // 映像フレームは捨てる
        @unknown default:
            return
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onUnexpectedStop(error)
    }
}
