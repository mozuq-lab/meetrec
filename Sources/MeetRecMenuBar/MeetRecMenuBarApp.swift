import AppKit
import SwiftUI

@main
struct MeetRecMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RecorderModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        RemoteControl.observe(model)
    }

    /// 録音中・ミックス中に終了するときは、ファイルを閉じてから終了する
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.needsCleanupBeforeQuit else { return .terminateNow }
        Task {
            await model.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
