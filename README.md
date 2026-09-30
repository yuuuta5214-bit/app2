# NCLogTools

ワイヤレーザー3Dプリンターの NCLog バイナリ (`.BIN`) から、次の2値をレコード単位で抽出・集計・出力する PowerShell 7 モジュールです。

| 列 | パラメーター | 内容 | 単位 |
|---|---|---|---|
| `Value40` | ADD_40_0 (`amPrcLg_output_pwr`) | 実レーザー出力パワー | % |
| `Value21` | ADD_21_0 (`realWirFeed_vel`) | 実ワイヤフィード速度 | mm/min |

## 必要環境

- PowerShell 7.2 以上 (Windows 推奨。Linux / macOS でも動作)
- テスト実行時のみ: Pester 5.5 以上、PSScriptAnalyzer (任意)

## いちばん簡単な使い方 (NCLogExport.cmd)

エクスプローラーから使えるランチャーです。PowerShell の知識は不要です。

| 操作 | 動作 |
|---|---|
| `NCLogExport.cmd` をダブルクリック | ファイル選択画面で .BIN を選ぶ (複数可) |
| .BIN ファイルを `NCLogExport.cmd` にドラッグ＆ドロップ | そのファイルを変換 |
| フォルダを `NCLogExport.cmd` にドラッグ＆ドロップ | フォルダ直下の .BIN をすべて変換 |

- CSV は元ファイルと同じフォルダに「元のファイル名.csv」で保存されます (Excel でそのまま開けます)。
- 同名の CSV がある場合は上書きするか確認します。
- 統計情報 (件数・最小・最大・平均・標準偏差) も表示します。
- PowerShell 7 が必要です。ない場合は案内が表示されます (`winget install --id Microsoft.PowerShell --source winget`)。
- **配布用 ZIP (`NCLogTools-<バージョン>.zip`) を丸ごと展開**して、展開したフォルダの `NCLogExport.cmd` を使ってください。`.cmd` だけをコピーしても動きません。
  ZIP は `./build/New-NCLogToolsPackage.ps1` で作成できます (`dist/` に出力)。
- コマンドラインで `-` から始まる引数を渡すと、`Export-NCLogValues.ps1` にそのまま渡します
  (例: `NCLogExport.cmd -Path C:\Logs\NCLog_*.BIN -Format JSON -OutputPath all.json`)。

## ビューアー (NCLogViewer.cmd)

.BIN の中身を画面で確認できる GUI です (Windows 専用・閲覧のみ)。

| 操作 | 動作 |
|---|---|
| `NCLogViewer.cmd` をダブルクリック | 空のビューアーを開く ([開く] / Ctrl+O、またはウィンドウへドラッグ＆ドロップ) |
| .BIN ファイルを `NCLogViewer.cmd` にドラッグ＆ドロップ | そのファイルを開く (1ファイル) |

| タブ | 内容 |
|---|---|
| レコード | No. / アドレス / ADD_40_0 (%) / ADD_21_0 (mm/min)。NaN・Infinity を含む無効レコードは赤。ダブルクリックで16進ダンプの該当位置へ |
| 16進ダンプ | ヘッダー (黄) / レコード (偶数・奇数で交互) / 末尾の端数 (赤) を色分け。選択したバイトを Int8～Int64・Single・Double で表示 |
| グラフ | 2値の推移。ホイールで拡大・縮小、ドラッグで移動、ダブルクリックで全体表示 |
| ファイル情報 | サイズ・レコード数・無効レコード数・端数バイト・統計・ヘッダーの 4 byte ごとの解釈 |

- ツールバーでヘッダー / レコードサイズ / 各値の位置を変えて [再解析] (Enter) できます。
  **末尾の端数が 0 byte になり、グラフが自然な形になるレイアウト**が実機ログに合ったレイアウトです。
- [CSV 出力] (Ctrl+E) は表示中のレイアウトで `Export-NCLogValue` と同じ CSV (UTF-8 BOM 付き) を作ります。
- ファイルは読み取り専用で開き、変更しません。16MB を超えるファイルは開けません。
- PowerShell からは `Show-NCLogViewer 'C:\Logs\NCLog_00000000_00003044.BIN'` で起動できます。

## 使い方 (PowerShell)

```powershell
Import-Module .\NCLogTools

# レコードを取得
Get-NCLogRecord 'C:\Logs\NCLog_*.BIN' -HideZeros | Where-Object Value40 -gt 50

# 統計
Get-NCLogRecord 'C:\Logs\NCLog_*.BIN' | Measure-NCLogRecord

# CSV に保存 (既存ファイルの上書きには -Force が必要)
Export-NCLogValue 'C:\Logs\NCLog_*.BIN' -Format CSV -OutputPath .\out.csv -Statistics

# GUI で閲覧 (Windows)
Show-NCLogViewer 'C:\Logs\NCLog_00000000_00003044.BIN'

# バイナリレイアウトの確認 (既定のオフセットが実機ログと合っているかの検証用)
(Get-NCLogFileInfo .\NCLog_00000000_00003044.BIN).Samples[0].Words | Format-Table
```

v1.0 からの呼び出し (`.\Export-NCLogValues.ps1 -FilePath ...`) はそのまま使えます (内部で `Export-NCLogValue` を呼ぶ互換ラッパー)。

詳しくは `Get-Help <コマンド名> -Full` を参照してください。

## バイナリレイアウト (既定値・要実機確認)

```
[Header 0x20 byte][Record 16 byte][Record 16 byte]...
Record: +4 = ADD_40_0 (float32 LE), +8 = ADD_21_0 (float32 LE)
```

異なる場合は `-HeaderSize` / `-RecordSize` / `-Value40Offset` / `-Value21Offset` で指定できます。

## テスト

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force   # 任意 (未導入なら該当テストはスキップ)

./build/Invoke-NCLogToolsTest.ps1          # 詳細表示
./build/Invoke-NCLogToolsTest.ps1 -CI      # TestResults/ に NUnit XML とカバレッジ (JaCoCo) を出力
```

GitHub Actions (`.github/workflows/pester.yml`) で windows-latest / ubuntu-latest の両方で実行されます。

ビューアーの画面 (`NCLogTools/Viewer/`) は CI で表示できないため、自動テストは
画面に依存しない処理 (`Private/`)、`Show-NCLogViewer` の引数処理、XAML の読み込み確認 (Windows) までです。
画面の操作は手動で確認してください。
