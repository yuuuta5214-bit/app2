# NCLogTools

ワイヤレーザー3Dプリンターの NCLog バイナリ (`.BIN`) から、次の2値をレコード単位で抽出・集計・出力する PowerShell 7 モジュールです。

| 列 | パラメーター | 内容 | 単位 |
|---|---|---|---|
| `Value40` | ADD_40_0 (`amPrcLg_output_pwr`) | 実レーザー出力パワー (UInt16) | W |
| `Value21` | ADD_21_0 (`realWirFeed_vel`) | 実ワイヤフィード速度 (Double ÷ 1000) | mm/min |

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

複数の .BIN をグラフで確認し、ファイルごとに名前を付けて CSV に一括出力する GUI です (Windows 専用)。

| 操作 | 動作 |
|---|---|
| `NCLogViewer.cmd` をダブルクリック | 空のビューアーを開く ([開く] / Ctrl+O で複数選択、またはウィンドウへドラッグ＆ドロップ) |
| .BIN ファイル・フォルダを `NCLogViewer.cmd` にドラッグ＆ドロップ | すべて開く (フォルダは直下の .BIN。最大 100 ファイル) |

### 作業手順 (画面左側を上から順に)

1. **ファイル一覧**: 開いたファイルが並びます。出力できる行は緑になります。
2. **グラフを右クリック**: 右クリックした位置のレーザー出力 (ADD_40_0) とワイヤ速度 (ADD_21_0) が入ります。
   取得した位置には緑の線が表示されます。値は直接入力もできます。
3. **割合を入力**: Enter を押すと次のファイルに移るので、続けて入力できます。
4. **一括 CSV 出力** (Ctrl+Shift+E): 出力できるファイルをすべて CSV に出力します。

出力ファイル名は `レーザー出力W_ワイヤ速度mm-min_割合%.csv` です (例: `2000W_1000mm-min_50%.csv`)。

- Windows のファイル名には `/` を使えないため、単位 mm/min は **mm-min** と書きます。
- 数値は小数第2位で四捨五入し、末尾の 0 は省きます (2000.0 → `2000`、12.345 → `12.35`)。全角数字も入力できます。
- 出力先フォルダを空欄にすると、各 BIN と同じフォルダに出力します。
- 出力先が同じになるファイル (同じ名前) がある場合は、どちらも出力できない状態になります。値を変えて区別してください。
- 既に同名の CSV がある場合は、上書き / スキップ / 中止 を確認します。
- CSV の中身は `Export-NCLogValue` と同じです (UTF-8 BOM 付き)。

### タブとメニュー

| 場所 | 内容 |
|---|---|
| グラフ タブ | 2値の推移。右クリックで値を取得、ドラッグで移動、ホイールで拡大・縮小、ダブルクリックで全体表示 |
| レコード タブ | No. / アドレス / ADD_40_0 / ADD_21_0。NaN・Infinity を含む無効レコードは赤。ダブルクリックで16進ダンプの該当位置へ |
| [ツール] → 16進ダンプを表示 | ヘッダー (黄) / レコード (偶数・奇数で交互) / 末尾の端数 (赤) を色分け。選択したバイトを Int8～Int64・Single・Double で表示 |
| [ツール] → ファイル情報を表示 | サイズ・レコード数・無効レコード数・端数バイト・統計・ヘッダーの 4 byte ごとの解釈 |
| [ツール] → レイアウト設定を表示 | ヘッダー / レコードサイズ / 各値の位置を変えて [再解析] (Enter)。開いているすべてのファイルに適用 |
| [ファイル] → 選択ファイルだけ CSV 出力 (Ctrl+E) | 保存先と名前を選んで1ファイルだけ出力 |
| [ヘルプ] → 使い方 (F1) | 作業手順を表示 |

- **末尾の端数が 0 byte になり、グラフが自然な形になるレイアウト**が実機ログに合ったレイアウトです。
- BIN ファイルは読み取り専用で開き、変更しません。1ファイル 16MB を超えるファイルは開けません。
- 大きなファイル (約 100 万レコード) も 1 秒未満で開けます。解析結果は選択中のファイルだけがメモリに持ち、
  ほかのファイルは選択したときに読み直すため、多数のファイルを開いてもメモリを使い切りません。
- 解析・統計・CSV 出力は C# (Add-Type) で高速化しています。会社の PC の設定などで Add-Type が使えない場合は、
  自動で PowerShell 版に切り替わります (結果は同じですが遅くなります)。
- 起動直後はステータスバーに「起動の準備中...」と表示されます (高速版の準備。1～数秒)。
- 動作が止まったときは [ヘルプ] → [診断ログを開く] で `%TEMP%\NCLogViewer.log` を確認できます。
  処理の段階と所要時間 (ファイル名・件数のみ。ファイルの中身は書きません) を記録しています。
- PowerShell からは `Show-NCLogViewer 'C:\Logs\NCLog_*.BIN'` で起動できます (複数ファイル可)。

## 使い方 (PowerShell)

```powershell
Import-Module .\NCLogTools

# レコードを取得
Get-NCLogRecord 'C:\Logs\NCLog_*.BIN' -HideZeros | Where-Object Value40 -gt 1000

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

## バイナリレイアウト

```
[Header 0x20 byte][Record 16 byte][Record 16 byte]...
Record: +4 = ADD_40_0 (UInt16 LE, 2 byte)  値はそのまま W
        +8 = ADD_21_0 (Double LE, 8 byte)  1000 で割った値が mm/min
```

- ADD_21_0 が NaN / ±Infinity のレコードは無効レコードとして除外します (CSV・統計の対象外)。
- 値の形式は `NCLogTools/Private/NCLogRecordFormat.ps1` で定義しています。

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
