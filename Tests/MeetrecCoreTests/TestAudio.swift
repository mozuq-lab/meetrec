import AVFoundation
@testable import MeetrecCore

enum TestAudio {
    static let sampleRate = 48_000.0

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetrecCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// サイン波（frequency が nil なら無音）の PCM バッファ。SCStream と同じ Float32 非インターリーブ
    static func tone(frequency: Double?, frames: Int, channels: Int, startFrame: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for i in 0..<frames {
                guard let frequency else { data[i] = 0; continue }
                data[i] = Float(0.5 * sin(2 * .pi * frequency * Double(startFrame + i) / sampleRate))
            }
        }
        return buffer
    }

    /// [start, end) 秒のサイン波を 10 ms ごとの CMSampleBuffer にして書き手に流す。skip の区間は送らない
    static func feed(
        _ writer: AudioFileWriter, channels: Int, frequency: Double,
        from start: Double, to end: Double, skipping skip: Range<Double>? = nil
    ) {
        let chunk = 480
        var frame = 0
        while start + Double(frame) / sampleRate < end {
            let time = start + Double(frame) / sampleRate
            defer { frame += chunk }
            if let skip, skip.contains(time) { continue }
            let pcm = tone(frequency: frequency, frames: chunk, channels: channels, startFrame: frame)
            let sampleBuffer = pcm.makeSampleBuffer(
                format: pcm.format.formatDescription,
                presentationTime: CMTime(seconds: time, preferredTimescale: 1_000_000_000)
            )!
            writer.queue.sync { writer.append(sampleBuffer) }
        }
    }

    /// AVAudioFile で AAC の m4a を書く（ミックスのテスト用）
    static func writeM4A(_ url: URL, channels: Int, segments: [(seconds: Double, frequency: Double?)]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        var startFrame = 0
        for segment in segments {
            let frames = Int(segment.seconds * sampleRate)
            try file.write(from: tone(frequency: segment.frequency, frames: frames, channels: channels, startFrame: startFrame))
            startFrame += frames
        }
    }

    /// ファイルの 1 チャンネル目の、各区間 [a, b) 秒の RMS (dB)
    static func levels(of url: URL, in windows: [(Double, Double)]) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        let rate = file.processingFormat.sampleRate
        return windows.map { window in
            let from = Int(window.0 * rate)
            let to = min(Int(window.1 * rate), Int(buffer.frameLength))
            guard to > from else { return -.infinity }
            var sum = 0.0
            for i in from..<to { sum += Double(data[i] * data[i]) }
            let rms = (sum / Double(to - from)).squareRoot()
            return rms > 0 ? 20 * log10(rms) : -.infinity
        }
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
