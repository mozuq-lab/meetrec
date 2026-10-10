import AVFoundation
import Testing
@testable import MeetrecCore

struct AudioFileWriterTests {
    /// system: 0〜2 秒（ステレオ）、mic: 0.5〜2 秒（モノラル、1.0〜1.3 秒が欠落）
    /// → mic は先頭 0.5 秒と欠落 0.3 秒が無音で埋まり、両方 2 秒になる
    @Test func alignsStartAndFillsGapsWithSilence() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory)
        let clock = SharedClock()
        let system = AudioFileWriter(track: .system, url: files.system, clock: clock, warn: { _ in })
        let mic = AudioFileWriter(track: .microphone, url: files.microphone, clock: clock, warn: { _ in })

        let base = 1000.0
        TestAudio.feed(system, channels: 2, frequency: 440, from: base, to: base + 2.0)
        TestAudio.feed(mic, channels: 1, frequency: 880, from: base + 0.5, to: base + 2.0,
                       skipping: (base + 1.0)..<(base + 1.3))

        let systemSummary = await system.finish()
        let micSummary = await mic.finish()

        #expect(systemSummary.error == nil)
        #expect(micSummary.error == nil)
        #expect(systemSummary.droppedBuffers == 0)
        #expect(micSummary.droppedBuffers == 0)
        #expect(abs(systemSummary.seconds - 2.0) < 0.01)
        #expect(abs(micSummary.seconds - 2.0) < 0.01)
        // 先頭の位置揃えは「途切れ」に数えない
        #expect(systemSummary.gapFilledSeconds == 0)
        #expect(abs(micSummary.gapFilledSeconds - 0.3) < 0.01)

        #expect(abs(try TestAudio.duration(of: files.system) - 2.0) < 0.05)
        #expect(abs(try TestAudio.duration(of: files.microphone) - 2.0) < 0.05)

        let micLevels = try TestAudio.levels(of: files.microphone, in: [
            (0.05, 0.45), // 先頭の位置揃え → 無音
            (0.60, 0.95), // 音あり
            (1.05, 1.25), // 欠落 → 無音
            (1.40, 1.90), // 音あり
        ])
        #expect(micLevels[0] < -80)
        #expect(micLevels[1] > -12)
        #expect(micLevels[2] < -80)
        #expect(micLevels[3] > -12)

        let systemLevels = try TestAudio.levels(of: files.system, in: [(0.05, 1.95)])
        #expect(systemLevels[0] > -12)
    }

    @Test func ignoresSamplesAfterFinish() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory)
        let writer = AudioFileWriter(track: .system, url: files.system, clock: SharedClock(), warn: { _ in })

        TestAudio.feed(writer, channels: 2, frequency: 440, from: 0, to: 0.5)
        let summary = await writer.finish()
        TestAudio.feed(writer, channels: 2, frequency: 440, from: 0.5, to: 1.0)

        #expect(summary.error == nil)
        #expect(abs(try TestAudio.duration(of: files.system) - 0.5) < 0.05)
    }

    @Test func doesNotCreateFileWithoutSamples() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory)
        let writer = AudioFileWriter(track: .microphone, url: files.microphone, clock: SharedClock(), warn: { _ in })

        let summary = await writer.finish()

        #expect(!summary.fileCreated)
        #expect(!FileManager.default.fileExists(atPath: files.microphone.path))
    }
}
