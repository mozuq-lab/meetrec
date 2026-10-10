# テスト用の音声

録音の動作確認で、システム音声として再生する音声です。

| ファイル | 内容 |
| --- | --- |
| `speech.m4a` | 「これは meetrec の録音テストです。システム音声とマイクを同時に録音しています。」の読み上げ（約 6 秒、`say` で作成） |

録音中に別のターミナルで再生すると、`_system.m4a` に入ります。スピーカーから鳴らせば、マイク側にも入ります。

```sh
afplay test-audio/speech.m4a
```

録音できたかは、ffmpeg の volumedetect で確かめられます。完全な無音なら -91 dB 前後になります。

```sh
ffmpeg -i ~/Recordings/<日時>_system.m4a -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume'
```

なお、`swift test` のテストはこのファイルを使いません。テストに使う音声（サイン波）はテストの中で作っています。
