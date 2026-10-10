import Foundation

/// 同じ Mac のスクリプトやショートカットから録音を操作するための分散通知。
/// URL スキームと違い、Web ページからは送れない。
enum RemoteControl {
    static let start = Notification.Name("local.meetrec.MeetRec.start")
    static let stop = Notification.Name("local.meetrec.MeetRec.stop")
    static let toggle = Notification.Name("local.meetrec.MeetRec.toggle")

    @MainActor
    static func observe(_ model: RecorderModel) {
        let center = DistributedNotificationCenter.default()
        _ = center.addObserver(forName: start, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.start() }
        }
        _ = center.addObserver(forName: stop, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.stop() }
        }
        _ = center.addObserver(forName: toggle, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.toggle() }
        }
    }
}
