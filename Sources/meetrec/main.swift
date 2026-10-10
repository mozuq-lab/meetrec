import Foundation
import MeetrecCore

enum ExitCode {
    static let usage: Int32 = 64      // EX_USAGE
    static let permission: Int32 = 77 // EX_NOPERM
    static let interrupted: Int32 = 130
}

struct Options {
    var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var showHelp = false

    static let usage = """
    使い方: meetrec [--out <ディレクトリ>]

    マイクとシステム音声を、別々の m4a (AAC) ファイルに同時録音します。
    Ctrl+C で録音を停止し、ファイルを閉じて終了します。

    オプション:
      -o, --out <dir>  保存先ディレクトリ（省略時はカレントディレクトリ。なければ作成）
      -h, --help       このヘルプを表示

    出力:
      <dir>/<yyyyMMdd-HHmmss>_system.m4a  システム音声
      <dir>/<yyyyMMdd-HHmmss>_mic.m4a     マイク
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "-o", "--out":
                guard let path = rest.popFirst() else {
                    throw MeetrecError("\(argument) には保存先ディレクトリを指定してください")
                }
                options.outputDirectory = directoryURL(path)
            case _ where argument.hasPrefix("--out="):
                options.outputDirectory = directoryURL(String(argument.dropFirst("--out=".count)))
            default:
                throw MeetrecError("不明な引数です: \(argument)")
            }
        }
        return options
    }

    private static func directoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

@MainActor
final class App {
    private let options: Options
    private var recorder: Recorder?
    private var signalSources: [any DispatchSourceSignal] = []
    private var ticker: (any DispatchSourceTimer)?
    private var startedAt = Date()
    private var isStopping = false

    init(options: Options) {
        self.options = options
    }

    func run() async {
        let missing = await Permissions.missing {
            Console.info("マイクへのアクセス許可を求めています。表示されたダイアログで「許可」を選んでください…")
        }
        guard missing.isEmpty else {
            Console.error(PermissionGuide.text(for: missing))
            exit(ExitCode.permission)
        }

        let directory = options.outputDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Console.error("保存先ディレクトリを作成できません: \(directory.path)\n\(error.localizedDescription)")
            exit(1)
        }

        let files = RecordingFiles(directory: directory)
        if let existing = files.existing.first {
            Console.error("同名のファイルが既にあります: \(existing.path)")
            exit(1)
        }

        let recorder = Recorder(files: files) { warning in
            Console.warn(warning)
        } onUnexpectedStop: { error in
            Task { @MainActor in await self.stop(dueTo: error) }
        }
        installSignalHandlers()
        do {
            try await recorder.start()
        } catch {
            if Permissions.isDeniedError(error) {
                Console.error(PermissionGuide.text(for: [.screenRecording]))
                exit(ExitCode.permission)
            }
            Console.error("録音を開始できませんでした: \(error.localizedDescription)")
            exit(1)
        }
        self.recorder = recorder
        startedAt = Date()

        Console.info("録音を開始しました（Ctrl+C で停止）")
        Console.info("  システム音声: \(files.system.path)")
        Console.info("  マイク      : \(files.microphone.path)（\(Recorder.microphoneName ?? "既定の入力")）")
        startTicker()
    }

    // MARK: - 停止

    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN) // ターミナルを閉じた後の書き込みで落ちないように
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.handleSignal() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func handleSignal() {
        if isStopping {
            Console.error("強制終了します（ファイルが正しく閉じられていない可能性があります）")
            exit(ExitCode.interrupted)
        }
        Task { await stop(dueTo: nil) }
    }

    private func stop(dueTo error: Error?) async {
        guard !isStopping else { return }
        isStopping = true
        ticker?.cancel()
        Console.clearStatus()

        guard let recorder else {
            // 録音開始前に中断された
            exit(ExitCode.interrupted)
        }
        if let error {
            Console.error("録音が中断されました: \(error.localizedDescription)")
        }
        Console.info("停止しています…")

        let summaries = await recorder.stop()
        let ok = report(summaries)
        exit(error == nil && ok ? 0 : 1)
    }

    /// 結果を表示し、両方のファイルが正常に書けたかを返す
    private func report(_ summaries: [TrackSummary]) -> Bool {
        var ok = true
        // 標準出力がパイプやリダイレクトのときは、保存したファイルのパスだけを 1 行ずつ出す
        let printsPaths = isatty(STDOUT_FILENO) == 0
        Console.info("録音を保存しました（\(Self.formatDuration(Date().timeIntervalSince(startedAt)))）")
        for summary in summaries {
            let name = summary.track == .system ? "システム音声" : "マイク      "
            guard summary.fileCreated else {
                Console.warn("\(name.trimmingCharacters(in: .whitespaces)): 音声を受信しなかったため、ファイルは作成されませんでした")
                ok = false
                continue
            }
            var notes = [Self.formatDuration(summary.seconds)]
            if summary.gapFilledSeconds >= 0.1 {
                notes.append(String(format: "途切れた %.1f 秒を無音で補完", summary.gapFilledSeconds))
            }
            if summary.droppedBuffers > 0 {
                notes.append("取りこぼし \(summary.droppedBuffers) 回")
            }
            Console.info("  \(name): \(summary.url.path)（\(notes.joined(separator: "、"))）")
            if let error = summary.error {
                Console.warn("\(name.trimmingCharacters(in: .whitespaces)): \(error)")
                ok = false
            }
            if printsPaths {
                print(summary.url.path)
            }
        }
        return ok
    }

    // MARK: - 経過時間の表示

    private func startTicker() {
        let interactive = Console.isInteractive
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // TTY ではその場で更新、パイプやログへの出力時は 10 秒ごとに 1 行
        timer.schedule(deadline: .now() + (interactive ? 0 : 10), repeating: interactive ? 0.5 : 10)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick(interactive: interactive) }
        }
        timer.resume()
        ticker = timer
    }

    private func tick(interactive: Bool) {
        let elapsed = Self.formatDuration(Date().timeIntervalSince(startedAt))
        if interactive {
            Console.status("● 録音中 \(elapsed)  （Ctrl+C で停止）")
        } else {
            Console.info("録音中 \(elapsed)")
        }
    }

    // MARK: - 書式

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

// MARK: - エントリポイント

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    Console.error("\(error.localizedDescription)\n\n\(Options.usage)")
    exit(ExitCode.usage)
}
if options.showHelp {
    print(Options.usage)
    exit(0)
}

let app = App(options: options)
Task { await app.run() }
dispatchMain()
