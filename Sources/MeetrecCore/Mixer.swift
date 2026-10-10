import AVFoundation

public enum Mixer {
    /// 複数の音声ファイルを 0 秒から重ね、1 つの m4a (AAC) に書き出す。
    /// 音量はそのまま足し合わせる（ffmpeg の amix=normalize=0 相当）。長さは最も長い入力に合わせる。
    public static func mix(_ inputs: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        for url in inputs {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MeetrecError("音声トラックがありません: \(url.lastPathComponent)")
            }
            let range = try await source.load(.timeRange)
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MeetrecError("ミックス用のトラックを作れません")
            }
            try track.insertTimeRange(range, of: source, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetrecError("ミックスの書き出しを準備できません")
        }
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: output) // 中断・失敗時の書きかけを残さない
            throw error
        }
    }
}
