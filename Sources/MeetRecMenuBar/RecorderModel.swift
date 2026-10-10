import AppKit
import MeetrecCore
import Observation

@MainActor
@Observable
final class RecorderModel {
    enum Phase {
        case idle
        case starting
        case recording
        case saving
    }

    private enum Keys {
        static let outputDirectory = "outputDirectory"
        static let mixAfterStop = "mixAfterStop"
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var microphoneName: String?
    private(set) var isMixing = false
    /// 直前の録音で保存したファイル（ミックス版ができたら追加される）
    private(set) var lastRecording: [URL] = []
    private(set) var warnings: [String] = []

    var outputDirectory: URL {
        didSet { UserDefaults.standard.set(outputDirectory.path, forKey: Keys.outputDirectory) }
    }
    var mixAfterStop: Bool {
        didSet { UserDefaults.standard.set(mixAfterStop, forKey: Keys.mixAfterStop) }
    }

    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var files: RecordingFiles?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var mixTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        outputDirectory = defaults.string(forKey: Keys.outputDirectory).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings")
        mixAfterStop = defaults.object(forKey: Keys.mixAfterStop) as? Bool ?? true
    }

    var elapsedText: String {
        let total = Int(elapsed)
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    var outputDirectoryText: String {
        (outputDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - 録音

    func start() {
        guard phase == .idle else { return }
        Task { await startRecording() }
    }

    func stop() {
        guard phase == .recording else { return }
        Task { await stopRecording(dueTo: nil, mix: mixAfterStop) }
    }

    func toggle() {
        phase == .idle ? start() : stop()
    }

    private func startRecording() async {
        phase = .starting
        warnings = []

        let missing = await Permissions.missing()
        guard missing.isEmpty else {
            phase = .idle
            Alerts.permissionsMissing(missing)
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .idle
            Alerts.show("保存先フォルダを作成できません", "\(outputDirectoryText)\n\(error.localizedDescription)")
            return
        }
        let files = RecordingFiles(directory: outputDirectory)
        if let existing = files.existing.first {
            phase = .idle
            Alerts.show("同名のファイルが既にあります", existing.path)
            return
        }

        // モデルはアプリの終了まで生きるので、強参照で持ってよい
        let recorder = Recorder(files: files) { warning in
            Task { @MainActor in self.warnings.append(warning) }
        } onUnexpectedStop: { error in
            Task { @MainActor in await self.stopRecording(dueTo: error, mix: self.mixAfterStop) }
        }
        do {
            try await recorder.start()
        } catch {
            phase = .idle
            if Permissions.isDeniedError(error) {
                Alerts.permissionsMissing([.screenRecording])
            } else {
                Alerts.show("録音を開始できませんでした", error.localizedDescription)
            }
            return
        }

        self.recorder = recorder
        self.files = files
        microphoneName = Recorder.microphoneName
        startedAt = Date()
        elapsed = 0
        phase = .recording

        // メニューを開いている間（イベントトラッキング中）も更新されるよう .common に登録する
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.elapsed = Date().timeIntervalSince(self.startedAt) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopRecording(dueTo error: Error?, mix: Bool) async {
        guard phase == .recording, let recorder, let files else { return }
        phase = .saving
        timer?.invalidate()
        timer = nil

        let summaries = await recorder.stop()
        self.recorder = nil
        self.files = nil
        lastRecording = summaries.filter(\.fileCreated).map(\.url)
        phase = .idle

        var problems: [String] = []
        for summary in summaries {
            let name = summary.track == .system ? "システム音声" : "マイク"
            if !summary.fileCreated {
                problems.append("\(name): 音声を受信しなかったため、ファイルは作成されませんでした")
            } else if let message = summary.error {
                problems.append("\(name): \(message)")
            }
        }
        if let error {
            Alerts.show("録音が中断されました", ([error.localizedDescription, "それまでの音声は保存しました。"] + problems).joined(separator: "\n"))
        } else if !problems.isEmpty {
            Alerts.show("録音の保存中に問題がありました", problems.joined(separator: "\n"))
        }

        if mix, lastRecording.count == 2 {
            enqueueMix(files)
        }
    }

    /// ミックスは録音と並行して進めてよい。複数たまったら順番に処理する
    private func enqueueMix(_ files: RecordingFiles) {
        isMixing = true
        let previous = mixTask
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await Mixer.mix([files.system, files.microphone], to: files.mix)
                if lastRecording.first == files.system {
                    lastRecording.append(files.mix)
                }
            } catch {
                // 終了時に中断した場合は何も出さない（別々のファイルは保存済み）
                if !Task.isCancelled {
                    Alerts.show("ミックス版を作成できませんでした", "\(files.mix.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
        }
        mixTask = task
        Task {
            await task.value
            if mixTask == task {
                mixTask = nil
                isMixing = false
            }
        }
    }

    // MARK: - 終了

    var needsCleanupBeforeQuit: Bool {
        phase != .idle || mixTask != nil
    }

    /// 録音中なら停止してファイルを閉じる（ミックスはしない）。ミックス中なら中断する
    func prepareForQuit() async {
        while phase == .starting || phase == .saving {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if phase == .recording {
            await stopRecording(dueTo: nil, mix: false)
        }
        mixTask?.cancel()
        await mixTask?.value
    }

    // MARK: - 保存先

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = "選択"
        panel.message = "録音ファイルの保存先フォルダを選んでください"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    func openOutputDirectory() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    func revealLastRecording() {
        NSWorkspace.shared.activateFileViewerSelecting(lastRecording)
    }
}
