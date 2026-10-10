import AVFoundation
import CoreMedia

public enum Track: String, Sendable {
    case system
    case microphone

    /// ログ用の短い名前
    var label: String { self == .system ? "system" : "mic" }
}

/// 1 トラック分の書き出し結果
public struct TrackSummary: Sendable {
    public let track: Track
    public let url: URL
    public let fileCreated: Bool
    public let seconds: Double
    /// 録音途中の途切れを無音で埋めた合計（先頭の位置揃えは含まない）
    public let gapFilledSeconds: Double
    public let droppedBuffers: Int
    public let error: String?
}

/// システム音声とマイクで共有する時間の原点。最初に届いたサンプルの時刻を 0 秒とする。
final class SharedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var originTime: CMTime?

    func origin(proposing time: CMTime) -> CMTime {
        lock.withLock {
            if let originTime { return originTime }
            originTime = time
            return time
        }
    }
}

/// 1 トラック分の PCM サンプルを AAC (.m4a) に書き出す。
///
/// 書き出すサンプルは「原点からのフレーム数」で振り直した連続したタイムラインに並べる。
/// 先頭のずれや途中の途切れは無音で埋めるので、2 ファイルの 0 秒は同じ瞬間になる。
/// 状態はすべて `queue` 上でのみ触る（SCStream のサンプルハンドラもこのキューで呼ばれる）。
final class AudioFileWriter: @unchecked Sendable {
    /// これを超えてサンプルの時刻が先に進んでいたら、その分を無音で埋める
    private static let gapTolerance = 0.05
    /// 先頭の揃え込みでこれ以上ずれていたら時計が別物とみなし、揃えずにそのまま書く
    private static let maxStartOffset = 5.0

    let track: Track
    let url: URL
    let queue: DispatchQueue
    private let clock: SharedClock
    private let warn: @Sendable (String) -> Void

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var formatDescription: CMAudioFormatDescription?
    private var pcmFormat: AVAudioFormat?
    private var sampleRate: Double = 0
    private var timescale: CMTimeScale = 0
    private var origin: CMTime = .invalid
    private var framesWritten: Int64 = 0
    private var gapFilledFrames: Int64 = 0
    private var droppedBuffers = 0
    private var warnedFormatChange = false
    private var failure: String?
    private var finished = false

    init(track: Track, url: URL, clock: SharedClock, warn: @escaping @Sendable (String) -> Void) {
        self.track = track
        self.url = url
        self.clock = clock
        self.warn = warn
        self.queue = DispatchQueue(label: "meetrec.writer.\(track.label)")
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, failure == nil else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let format = sampleBuffer.formatDescription else { return }

        let pts = sampleBuffer.presentationTimeStamp
        if writer == nil {
            do {
                try startWriting(format: format, firstTime: pts)
            } catch {
                fail("書き出しを開始できません: \(error.localizedDescription)")
                return
            }
        }
        guard let writer, let input else { return }

        guard sameFormat(format) else {
            if !warnedFormatChange {
                warnedFormatChange = true
                warn("[\(track.label)] 録音中に入力フォーマットが変わりました。以降の音声は書き出せません（\(describe(format))）")
            }
            droppedBuffers += 1
            return
        }

        let frames = Int64(sampleBuffer.numSamples)
        // このバッファが本来置かれるべき位置（原点からのフレーム数）
        let expected = Int64(((pts - origin).seconds * sampleRate).rounded())
        if expected + frames <= 0 { return } // 原点より前の音

        if Double(expected - framesWritten) / sampleRate > Self.gapTolerance {
            appendSilence(frames: expected - framesWritten, to: input)
        }

        guard input.isReadyForMoreMediaData else {
            droppedBuffers += 1
            return
        }
        do {
            let timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: timescale),
                presentationTimeStamp: time(at: framesWritten),
                decodeTimeStamp: .invalid
            )
            let retimed = try CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing])
            if input.append(retimed) {
                framesWritten += frames
            } else {
                fail("書き込みに失敗しました: \(writer.error?.localizedDescription ?? "不明なエラー")")
            }
        } catch {
            fail("サンプルの処理に失敗しました: \(error.localizedDescription)")
        }
    }

    /// 書き出しを完了してファイルを閉じる。以降に届いたサンプルは無視する。
    func finish() async -> TrackSummary {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                guard let writer = self.writer, let input = self.input, writer.status == .writing else {
                    continuation.resume(returning: self.summary())
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        if let writer = self.writer, writer.status != .completed {
                            self.failure = self.failure
                                ?? "ファイルを閉じられませんでした: \(writer.error?.localizedDescription ?? "不明なエラー")"
                        }
                        continuation.resume(returning: self.summary())
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func startWriting(format: CMAudioFormatDescription, firstTime: CMTime) throws {
        guard let asbd = format.audioStreamBasicDescription, asbd.mFormatID == kAudioFormatLinearPCM else {
            throw MeetrecError("未対応の音声フォーマットです（\(describe(format))）")
        }

        sampleRate = asbd.mSampleRate
        timescale = CMTimeScale(asbd.mSampleRate.rounded())
        formatDescription = format
        pcmFormat = AVAudioFormat(cmAudioFormatDescription: format)

        let sharedOrigin = clock.origin(proposing: firstTime)
        if abs((firstTime - sharedOrigin).seconds) > Self.maxStartOffset {
            warn("[\(track.label)] もう一方のトラックと時刻が大きくずれているため、先頭を揃えずに録音します")
            origin = firstTime
        } else {
            origin = sharedOrigin
        }

        let channels = Int(asbd.mChannelsPerFrame)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(sampleRate, 48_000),
            AVNumberOfChannelsKey: min(channels, 2),
            AVEncoderBitRateKey: 64_000 * min(channels, 2),
        ]
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
            // サンプルレートによっては指定ビットレートが使えないので、エンコーダの既定値に任せる
            settings[AVEncoderBitRateKey] = nil
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MeetrecError("AAC エンコーダを設定できません（\(describe(format))）")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MeetrecError("AVAssetWriter を開始できません")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
    }

    private func appendSilence(frames total: Int64, to input: AVAssetWriterInput) {
        let isLeading = framesWritten == 0 // 先頭はもう一方のトラックとの位置揃え
        var remaining = total
        while remaining > 0 {
            let frames = min(remaining, Int64(sampleRate)) // 1 秒ずつ
            guard input.isReadyForMoreMediaData,
                  let buffer = makeSilence(frames: frames, at: framesWritten),
                  input.append(buffer)
            else { return } // 残りは次のバッファで再度埋める
            framesWritten += frames
            if !isLeading { gapFilledFrames += frames }
            remaining -= frames
        }
    }

    private func makeSilence(frames: Int64, at position: Int64) -> CMSampleBuffer? {
        guard let pcmFormat, let formatDescription,
              let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        pcm.frameLength = pcm.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return pcm.makeSampleBuffer(format: formatDescription, presentationTime: time(at: position))
    }

    private func sameFormat(_ format: CMAudioFormatDescription) -> Bool {
        guard let current = formatDescription?.audioStreamBasicDescription,
              let incoming = format.audioStreamBasicDescription else { return false }
        return current.mSampleRate == incoming.mSampleRate
            && current.mChannelsPerFrame == incoming.mChannelsPerFrame
            && current.mFormatFlags == incoming.mFormatFlags
            && current.mBitsPerChannel == incoming.mBitsPerChannel
    }

    private func time(at frame: Int64) -> CMTime {
        CMTime(value: frame, timescale: timescale)
    }

    private func fail(_ message: String) {
        failure = message
        warn("[\(track.label)] \(message)")
    }

    private func describe(_ format: CMAudioFormatDescription) -> String {
        guard let asbd = format.audioStreamBasicDescription else { return "不明" }
        return "\(Int(asbd.mSampleRate)) Hz / \(asbd.mChannelsPerFrame) ch"
    }

    private func summary() -> TrackSummary {
        TrackSummary(
            track: track,
            url: url,
            fileCreated: writer != nil,
            seconds: sampleRate > 0 ? Double(framesWritten) / sampleRate : 0,
            gapFilledSeconds: sampleRate > 0 ? Double(gapFilledFrames) / sampleRate : 0,
            droppedBuffers: droppedBuffers,
            error: failure
        )
    }
}

extension AVAudioPCMBuffer {
    /// PCM データを、指定した時刻から始まる CMSampleBuffer に包む
    func makeSampleBuffer(format: CMAudioFormatDescription, presentationTime: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(frameLength),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
