import Foundation

/// 標準エラー出力への表示。録音中のステータス行（\r で上書き）と、
/// 別スレッドから届く警告が混ざらないようにロックで直列化する。
enum Console {
    static let isInteractive = isatty(STDERR_FILENO) != 0

    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusLineVisible = false

    static func info(_ message: String) {
        writeLine(message)
    }

    static func warn(_ message: String) {
        writeLine("⚠️  " + message)
    }

    static func error(_ message: String) {
        writeLine(message)
    }

    /// 1 行のステータスをその場で書き換える（TTY のときのみ）
    static func status(_ message: String) {
        lock.withLock {
            fputs("\r\u{1B}[2K" + message, stderr)
            fflush(stderr)
            statusLineVisible = true
        }
    }

    static func clearStatus() {
        lock.withLock { clearStatusLocked() }
    }

    private static func writeLine(_ message: String) {
        lock.withLock {
            clearStatusLocked()
            fputs(message + "\n", stderr)
            fflush(stderr)
        }
    }

    private static func clearStatusLocked() {
        guard statusLineVisible else { return }
        fputs("\r\u{1B}[2K", stderr)
        statusLineVisible = false
    }
}
