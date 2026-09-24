#Requires -Version 7.2

<#
.SYNOPSIS
    NCLog (.BIN) を CSV に変換する対話用ランチャー (NCLogExport.cmd から起動)。

.DESCRIPTION
    NCLogExport.cmd のダブルクリック / ドラッグ＆ドロップから呼ばれ、
    選択された各 NCLog ファイルを Export-NCLogValues.ps1 で CSV に変換します。

    - 引数なし      : ファイル選択ダイアログ (複数選択可) を表示します。
    - ファイル指定  : そのファイルを変換します。
    - フォルダ指定  : フォルダ直下の *.BIN をすべて変換します。

    CSV は元ファイルと同じフォルダに「元のファイル名.csv」で保存し、統計情報も表示します。
    同名の CSV が既にある場合は上書きするか確認します (-Force で確認なしに上書き)。
    非対話モード (pwsh -NonInteractive) では確認できないため、既存ファイルはスキップします。

.PARAMETER Path
    変換する NCLog ファイルまたはフォルダ。ワイルドカードとして解釈しません。
    ドラッグ＆ドロップされたパスがここに入ります。

.PARAMETER Force
    既存の CSV を確認なしで上書きします。

.PARAMETER NoPause
    終了前に Enter キー待ちをしません (自動実行・テスト用)。

.INPUTS
    None

.OUTPUTS
    None。作成した CSV のパスをホストに表示します。
    終了コード: 0 = すべて成功 / 1 = 失敗あり / 2 = 対象ファイルなし

.EXAMPLE
    .\tools\Start-NCLogExport.ps1

    ファイル選択ダイアログを表示します。

.EXAMPLE
    .\tools\Start-NCLogExport.ps1 'C:\Logs\NCLog_00000000_00003044.BIN' 'C:\Logs\2026-09'

    1ファイルと、フォルダ内の全 .BIN を CSV に変換します。

.NOTES
    通常は NCLogExport.cmd から起動してください。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Path,

    [switch]$Force,

    [switch]$NoPause
)

Set-StrictMode -Version 3.0

$exporter = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Export-NCLogValues.ps1'
$exporter = [System.IO.Path]::GetFullPath($exporter)

function Test-NCLogInteractive {
    <#
    .SYNOPSIS
        ユーザーに確認・入力を求めてよい実行環境かを判定する。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $nonInteractive = [Environment]::GetCommandLineArgs() |
        Where-Object { $_ -match '^-noni' }   # -NonInteractive とその省略形
    [Environment]::UserInteractive -and -not $nonInteractive -and -not [Console]::IsInputRedirected
}

function Select-NCLogFile {
    <#
    .SYNOPSIS
        ファイル選択ダイアログで NCLog ファイルを選ばせる (Windows のみ)。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $IsWindows) {
        $answer = Read-Host 'NCLog ファイルのパスを入力してください (空欄で終了)'
        if ($answer) { $answer.Trim('"', ' ') }
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    # ダイアログがコンソールの裏に隠れないよう、最前面の透明なオーナーを使う
    $owner = [System.Windows.Forms.Form]@{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    try {
        $dialog.Title = 'CSV に変換する NCLog ファイルを選択 (複数選択可)'
        $dialog.Filter = 'NCLog ファイル (*.BIN)|*.BIN|すべてのファイル (*.*)|*.*'
        $dialog.Multiselect = $true
        $dialog.CheckFileExists = $true
        $dialog.RestoreDirectory = $true
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            $dialog.FileNames
        }
    }
    finally {
        $dialog.Dispose()
        $owner.Dispose()
    }
}

function Resolve-NCLogTarget {
    <#
    .SYNOPSIS
        ファイル/フォルダの指定を、変換対象の .BIN ファイル一覧に展開する。
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$InputPath
    )

    foreach ($p in $InputPath) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            Write-Warning "見つかりません: $p"
        }
        elseif ($item.PSIsContainer) {
            $files = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.BIN' -File)
            if ($files.Count -eq 0) { Write-Warning ".BIN ファイルがありません: $($item.FullName)" }
            $files
        }
        else {
            $item
        }
    }
}

function Confirm-NCLogOverwrite {
    <#
    .SYNOPSIS
        既存 CSV を上書きしてよいか確認する。確認できない環境では $false。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$FilePath
    )

    if (-not (Test-NCLogInteractive)) { return $false }
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', '上書きする')
        [System.Management.Automation.Host.ChoiceDescription]::new('&No', 'このファイルはスキップする')
    )
    try {
        $Host.UI.PromptForChoice('上書き確認', "既に存在します: $FilePath`n上書きしますか?", $choices, 1) -eq 0
    }
    catch [System.Management.Automation.PSInvalidOperationException] {
        $false   # 非対話ホスト
    }
}

# ---------------------------------------------------------------------------
$exitCode = 0
try {
    if (-not (Test-Path -LiteralPath $exporter -PathType Leaf)) {
        throw "Export-NCLogValues.ps1 が見つかりません: $exporter"
    }

    Write-Host 'NCLog → CSV 変換' -ForegroundColor Cyan

    if (-not $Path) {
        $Path = @(Select-NCLogFile)
    }
    $targets = @(Resolve-NCLogTarget -InputPath @($Path) | Sort-Object FullName -Unique)

    if ($targets.Count -eq 0) {
        Write-Host '変換するファイルがありません。'
        $exitCode = 2
    }
    else {
        $ok = [System.Collections.Generic.List[string]]::new()
        $skipped = [System.Collections.Generic.List[string]]::new()
        $failed = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $targets) {
            $csv = [System.IO.Path]::ChangeExtension($file.FullName, '.csv')
            Write-Host ''
            Write-Host "▶ $($file.FullName)" -ForegroundColor Yellow

            $overwrite = $Force.IsPresent
            if ((Test-Path -LiteralPath $csv) -and -not $overwrite) {
                if (Confirm-NCLogOverwrite -FilePath $csv) {
                    $overwrite = $true
                }
                else {
                    Write-Host "  スキップ (既存の CSV を残しました): $csv"
                    $skipped.Add($file.FullName)
                    continue
                }
            }

            try {
                & $exporter -LiteralPath $file.FullName -Format CSV -OutputPath $csv -Statistics -Force:$overwrite -ErrorAction Stop
                if (Test-Path -LiteralPath $csv) {
                    $ok.Add($csv)
                }
                else {
                    # データなし (警告のみ) の場合は CSV が作られない
                    $failed.Add($file.FullName)
                }
            }
            catch {
                Write-Host "  エラー: $($_.Exception.Message)" -ForegroundColor Red
                $failed.Add($file.FullName)
            }
        }

        Write-Host ''
        Write-Host ('─' * 60) -ForegroundColor Cyan
        Write-Host "完了: 成功 $($ok.Count) / スキップ $($skipped.Count) / 失敗 $($failed.Count)" -ForegroundColor Cyan
        foreach ($c in $ok) { Write-Host "  ✓ $c" -ForegroundColor Green }
        foreach ($f in $failed) { Write-Host "  ✗ $f" -ForegroundColor Red }

        if ($failed.Count -gt 0) { $exitCode = 1 }

        # 作成した CSV をエクスプローラーで表示 (Windows・対話時のみ、確認あり)
        if ($IsWindows -and $ok.Count -gt 0 -and -not $NoPause -and (Test-NCLogInteractive)) {
            $open = Read-Host 'CSV の場所をエクスプローラーで開きますか? [y/N]'
            if ($open -match '^(y|yes)$') {
                Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($ok[0])`""
            }
        }
    }
}
catch {
    Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # ダブルクリック起動時にウィンドウがすぐ閉じて結果が読めないのを防ぐ
    if (-not $NoPause -and (Test-NCLogInteractive)) {
        $null = Read-Host 'Enter キーを押すと閉じます'
    }
}

exit $exitCode
