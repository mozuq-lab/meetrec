import AVFoundation
import Testing
@testable import MeetrecCore

struct MixerTests {
    /// system（ステレオ 2 秒、前半だけ音）と mic（モノラル 1.5 秒、1.0 秒以降に音）を重ねる
    @Test func mixesBothInputsForTheLongestDuration() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory)
        try TestAudio.writeM4A(files.system, channels: 2, segments: [(1.0, 440), (1.0, nil)])
        try TestAudio.writeM4A(files.microphone, channels: 1, segments: [(1.0, nil), (0.5, 880)])

        try await Mixer.mix([files.system, files.microphone], to: files.mix)

        let asset = AVURLAsset(url: files.mix)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try TestAudio.duration(of: files.mix) - 2.0) < 0.05)

        let levels = try TestAudio.levels(of: files.mix, in: [
            (0.20, 0.80), // system の音
            (1.10, 1.40), // mic の音
            (1.60, 1.90), // どちらも無音
        ])
        #expect(levels[0] > -12)
        #expect(levels[1] > -12)
        #expect(levels[2] < -60)
    }

    @Test func removesPartialOutputOnFailure() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RecordingFiles(directory: directory)
        try Data("not audio".utf8).write(to: files.system)

        await #expect(throws: (any Error).self) {
            try await Mixer.mix([files.system], to: files.mix)
        }
        #expect(!FileManager.default.fileExists(atPath: files.mix.path))
    }
}
