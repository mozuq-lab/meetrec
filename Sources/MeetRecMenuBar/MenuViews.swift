import AppKit
import SwiftUI

/// メニューバーに表示するアイコン。録音中は経過時間も出す
struct MenuBarLabel: View {
    let model: RecorderModel

    var body: some View {
        switch model.phase {
        case .recording:
            Image(systemName: "record.circle")
            Text(model.elapsedText)
        case .starting, .saving:
            Image(systemName: "ellipsis.circle")
        case .idle:
            Image(systemName: "waveform")
        }
    }
}

struct MenuContent: View {
    @Bindable var model: RecorderModel

    var body: some View {
        switch model.phase {
        case .idle:
            Button("録音を開始") { model.start() }
        case .starting:
            Text("録音を準備しています…")
        case .recording:
            Button("録音を停止") { model.stop() }
            Text("録音中 \(model.elapsedText)")
            if let microphone = model.microphoneName {
                Text("マイク: \(microphone)")
            }
        case .saving:
            Text("保存しています…")
        }
        if model.isMixing {
            Text("ミックス版を作成しています…")
        }
        ForEach(model.warnings.suffix(3), id: \.self) { warning in
            Text("⚠️ \(warning)")
        }

        Divider()

        Text("保存先: \(model.outputDirectoryText)")
        Button("保存先を変更…") { model.chooseOutputDirectory() }
            .disabled(model.phase != .idle)
        Button("保存先フォルダを開く") { model.openOutputDirectory() }
        Toggle("停止後にミックス版も保存", isOn: $model.mixAfterStop)

        if !model.lastRecording.isEmpty {
            Divider()
            Button("最後の録音を Finder で表示") { model.revealLastRecording() }
        }

        Divider()

        Button("MeetRec を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
