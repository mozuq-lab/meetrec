# meetrec

macOS 15 以降向けの、マイクとシステム音声を同時に録音するツールです。
ScreenCaptureKit の `SCStream` で両方を取り込み、別々の m4a (AAC) ファイルに保存します。
オンライン会議で「相手の声（システム音声）」と「自分の声（マイク）」を分けて残す用途を想定しています。

次の 2 つの形で使えます。録音の仕組みは共通です。

- **MeetRec.app**: メニューバーに常駐するアプリ
- **meetrec**: コマンドラインツール

## 動作要件

- macOS 15 (Sequoia) 以降
- Swift 6 のツールチェーン（Xcode 16 以降、または Command Line Tools）

## メニューバー版（MeetRec.app）

### ビルドとインストール

```sh
scripts/build-app.sh                  # build/MeetRec.app ができる
cp -R build/MeetRec.app /Applications/
open /Applications/MeetRec.app
```

起動するとメニューバーに波形のアイコンが出ます。Dock には表示されません。

### 使い方

メニューバーのアイコンをクリックし、「録音を開始」を選びます。録音中はメニューバーのアイコンの横に経過時間が表示されます。止めるときは、もう一度クリックして「録音を停止」を選びます。

| メニュー項目 | 内容 |
| --- | --- |
| 録音を開始 / 録音を停止 | 録音の開始と停止。録音中はメニュー内に経過時間と使用中のマイクも表示される |
| 保存先: ~/Recordings | 現在の保存先（初期値は `~/Recordings`） |
| 保存先を変更… | 保存先のフォルダを選ぶ（録音中は変更できない） |
| 保存先フォルダを開く | 保存先を Finder で開く |
| 停止後にミックス版も保存 | オンにすると、停止後に 2 つを重ねた `<日時>_mix.m4a` も作る（初期値はオン） |
| 最後の録音を Finder で表示 | 直前に保存したファイルを Finder で選択した状態で開く |
| MeetRec を終了 | 録音中に終了した場合は、ファイルを閉じてから終了する（ミックス版は作らない） |

保存されるファイルは CLI 版と同じです（[出力ファイル](#出力ファイル)）。ミックス版は ffmpeg を使わずにアプリ内で作ります。

### 権限

CLI 版と違い、権限は **MeetRec.app 自体** に与えます。

1. 初めて「録音を開始」を選ぶと、マイクと画面収録の許可を求めるダイアログが出ます。
2. マイクは、ダイアログで「許可」を選びます。
3. 画面収録は、「システム設定」>「プライバシーとセキュリティ」>「画面収録とシステムオーディオ録音」で MeetRec をオンにします。
4. 画面収録の権限は MeetRec を再起動すると有効になります。案内のダイアログにある「MeetRec を再起動」を選んでください。

### 署名と権限についての注意

`scripts/build-app.sh` は、キーチェーンにある証明書を次の順に探して署名します。

| 順 | 証明書 | 用途 |
| --- | --- | --- |
| 1 | 環境変数 `SIGN_IDENTITY` で指定したもの | 証明書の名前の一部か SHA-1 ハッシュで指定する。`-` なら ad-hoc 署名 |
| 2 | Developer ID Application | 他の Mac に配る場合。公証にはこれが必要（有料の Apple Developer Program） |
| 3 | Apple Development | 自分の Mac だけで使う場合（無料の Apple ID で作れる） |
| 4 | なし（ad-hoc 署名） | 証明書がない場合 |

どの証明書でも、hardened runtime を有効にし、`App/MeetRec.entitlements`（マイクを使う許可）を付けて署名します。証明書は Xcode の「設定」>「アカウント」>「証明書を管理」で作れます。

ad-hoc 署名の場合、macOS はビルドのたびに別のアプリとみなすので、**ビルドし直すたびに権限の設定がやり直しになります**。証明書で署名していれば、ビルドし直しても権限は引き継がれます。ただし、署名の種類を変えた（ad-hoc から Developer ID にした、など）ときは、一度だけやり直しになります。

権限の一覧に MeetRec が残っているのに録音できない場合は、古い記録を消してから許可し直します。

```sh
tccutil reset ScreenCapture com.mozuq-lab.MeetRec
tccutil reset Microphone com.mozuq-lab.MeetRec
```

### 他の Mac に配る（公証）

他の Mac で開くには、Developer ID Application 証明書で署名し、Apple の公証を受ける必要があります。公証を受けていないアプリは、ダウンロードしたりメールや AirDrop で受け取ったりすると、Gatekeeper に起動を止められます。

最初に 1 回だけ、公証用の認証情報をキーチェーンに保存します。パスワードは入力欄で聞かれるので、appleid.apple.com で作った **App 用パスワード** を入力します（通常のパスワードでは通りません）。

```sh
xcrun notarytool store-credentials meetrec-notary --apple-id <Apple ID> --team-id <チーム ID>
```

その後は、次のコマンドでビルドから公証までをまとめて実行できます。

```sh
scripts/build-app.sh --notarize
```

次の処理を順に行います。数分かかります。

1. Developer ID で署名する
2. 公証を申請し、結果を待つ
3. 公証の結果を .app に埋め込む（stapler）
4. Gatekeeper に通ることを確かめる
5. 配布用の `build/MeetRec.zip` を作る

公証に通らなかった場合は、Apple から返された理由を表示して止まります。キーチェーンプロファイルの名前を変えた場合は、`NOTARY_PROFILE` 環境変数で指定します。

配れるのは、macOS 15 以降の Apple シリコンの Mac だけです（Intel の Mac では動きません）。

### スクリプトから操作する

同じ Mac のスクリプトから、分散通知で録音を開始・停止できます。通知名は `com.mozuq-lab.MeetRec.start`、`com.mozuq-lab.MeetRec.stop`、`com.mozuq-lab.MeetRec.toggle` です。

```sh
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately($("com.mozuq-lab.MeetRec.toggle"), $(), $(), true)'
```

URL スキームと違い、Web ページからは操作できません。

## コマンドライン版（meetrec）

### CLI のビルドとインストール

```sh
swift build -c release --product meetrec
cp .build/release/meetrec /usr/local/bin/   # PATH の通ったディレクトリならどこでもよい
```

### CLI の使い方

```sh
meetrec --out ~/Recordings
```

録音中は経過時間を表示します。Ctrl+C で録音を止め、ファイルを閉じてから終了します。

```text
録音を開始しました（Ctrl+C で停止）
  システム音声: /Users/you/Recordings/20261008-135146_system.m4a
  マイク      : /Users/you/Recordings/20261008-135146_mic.m4a（MacBook Pro のマイク）
● 録音中 00:12:34  （Ctrl+C で停止）
```

```text
停止しています…
録音を保存しました（00:12:34）
  システム音声: /Users/you/Recordings/20261008-135146_system.m4a（00:12:34）
  マイク      : /Users/you/Recordings/20261008-135146_mic.m4a（00:12:34）
```

| オプション | 説明 |
| --- | --- |
| `-o`, `--out <dir>` | 保存先ディレクトリ。省略時はカレントディレクトリ。存在しなければ作成する |
| `-h`, `--help` | ヘルプを表示 |

- SIGTERM と SIGHUP（ターミナルを閉じたとき）でも、Ctrl+C と同じくファイルを閉じてから終了します。
- 停止処理中にもう一度 Ctrl+C を押すと、その場で強制終了します（ファイルが壊れることがあります）。
- 経過時間などの表示は標準エラー出力に出します。標準エラー出力が端末でない場合（パイプやリダイレクト）、経過時間は 10 秒ごとに 1 行ずつ出力します。
- 標準出力がパイプやリダイレクトの場合は、終了時に保存したファイルのパスだけを 1 行ずつ出力します（スクリプトから使う場合向け）。

### CLI の終了コード

| コード | 意味 |
| --- | --- |
| 0 | 正常終了 |
| 1 | 録音または書き出しのエラー |
| 64 | 引数の誤り |
| 77 | 権限がない |
| 130 | 録音開始前の中断、または強制終了 |

### CLI の権限

次の 2 つの権限が必要です。権限は meetrec 本体ではなく、**meetrec を起動したアプリ**（ターミナル、iTerm、VS Code など）に与えます。

- **画面収録とシステムオーディオ録音**: 「システム設定」>「プライバシーとセキュリティ」>「画面収録とシステムオーディオ録音」
- **マイク**: 「システム設定」>「プライバシーとセキュリティ」>「マイク」

初回実行時はシステムの許可ダイアログが表示されます。権限が足りない場合、meetrec は設定すべき項目を表示して終了します（終了コード 77）。画面収録の権限を付けた後は、ターミナルアプリの再起動が必要になることがあります。

## 出力ファイル

| ファイル | 内容 | 形式 |
| --- | --- | --- |
| `<yyyyMMdd-HHmmss>_system.m4a` | システム音声（録音しているアプリ自身の音は除外） | AAC 48 kHz ステレオ |
| `<yyyyMMdd-HHmmss>_mic.m4a` | システムの既定の入力デバイスの音声 | AAC（入力デバイスのサンプルレートとチャンネル数。上限は 48 kHz・2ch） |
| `<yyyyMMdd-HHmmss>_mix.m4a` | 上の 2 つを重ねたもの（メニューバー版で「停止後にミックス版も保存」がオンのとき） | AAC |

2 つのファイルは、先頭（0 秒）が同じ時刻になるように揃えてあります。片方の開始が遅れた場合や、録音中に音声が途切れた場合は、その分を無音で埋めます。そのため、時刻合わせをせずにそのまま重ねられます。

## 2 つのファイルを 1 つにミックスする（ffmpeg）

CLI 版で録音した場合は、ffmpeg で重ねます。

```sh
p=~/Recordings/20261008-135146   # 録音ファイルの共通部分

ffmpeg -i "${p}_system.m4a" -i "${p}_mic.m4a" \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0[out]" \
  -map "[out]" -c:a aac -b:a 128k "${p}_mix.m4a"
```

- `duration=longest`: 長いほうのファイルに合わせて最後まで出力します。
- `normalize=0`: それぞれの音量を下げずに足し合わせます。既定（`normalize=1`）では入力の数に応じて全体の音量が下がります。

マイクの声が小さい場合は、マイク側だけ音量を上げてから重ねます（例: 2 倍）。

```sh
ffmpeg -i "${p}_system.m4a" -i "${p}_mic.m4a" \
  -filter_complex "[1:a]volume=2.0[mic];[0:a][mic]amix=inputs=2:duration=longest:normalize=0[out]" \
  -map "[out]" -c:a aac -b:a 128k "${p}_mix.m4a"
```

## 開発

```sh
swift build        # すべてビルド
swift test         # 書き出し（先頭の位置揃え・途切れの無音補完）とミックスのテスト
```

| ディレクトリ | 内容 |
| --- | --- |
| `Sources/MeetrecCore` | 録音（`SCStream`）、m4a への書き出し、ミックスなどの共通部分 |
| `Sources/meetrec` | コマンドライン版 |
| `Sources/MeetRecMenuBar` | メニューバー版（SwiftUI の `MenuBarExtra`） |
| `App/Info.plist`, `App/MeetRec.entitlements`, `scripts/build-app.sh` | MeetRec.app の組み立て、署名、公証 |

## 仕組みと制限

- `SCStream` にディスプレイ全体のフィルタを設定し、`capturesAudio`（システム音声）と `captureMicrophone`（マイク）を有効にしています。`excludesCurrentProcessAudio` で録音しているアプリ自身の音は除外します。
- 映像は使いませんが、`SCStream` はディスプレイを対象にする必要があるため、2×2 ピクセル・1 fps の最小設定で受け取ってすぐに捨てています。
- マイクはシステムの既定の入力デバイスを使います。録音中に入力のフォーマット（サンプルレートやチャンネル数）が変わった場合は警告を表示し、それ以降のマイク音声は保存されません。
- m4a はファイルを閉じるときに索引を書き込みます。`kill -9` やクラッシュ、電源断で終了した場合、そのファイルは再生できません。
