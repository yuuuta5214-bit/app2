#Requires -Version 7.2

<#
.SYNOPSIS
    NCLog Viewer の起動用スクリプト (NCLogViewer.cmd から起動)。

.DESCRIPTION
    NCLogTools モジュールを読み込み、Show-NCLogViewer でビューアーを表示します。

    - 引数なし      : 空のビューアーを表示します ([開く] またはドラッグ＆ドロップでファイルを指定)。
    - ファイル指定  : 指定したファイルをすべて開きます (複数可)。
    - フォルダ指定  : フォルダ直下の .BIN をすべて開きます。

    コンソールは非表示で起動されるため、エラーはメッセージボックスで表示します。

.PARAMETER Path
    開く NCLog ファイルまたはフォルダ (複数可)。ワイルドカードとして解釈しません。
    ドラッグ＆ドロップされたパスがここに入ります。

.INPUTS
    None

.OUTPUTS
    None。終了コード: 0 = 正常終了 / 1 = エラー

.EXAMPLE
    .\tools\Start-NCLogViewer.ps1 'C:\Logs\NCLog_00000000_00003044.BIN'

    ファイルを開いてビューアーを表示します。

.NOTES
    通常は NCLogViewer.cmd から起動してください。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Path
)

Set-StrictMode -Version 3.0

function Show-NCLogLauncherError {
    <#
    .SYNOPSIS
        起動時のエラーを表示する (Windows ではメッセージボックス)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    if ($IsWindows) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [void][System.Windows.MessageBox]::Show($Message, 'NCLog Viewer',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        catch {
            Write-Verbose "メッセージボックスを表示できません: $_"
        }
    }
    Write-Error -Message $Message -ErrorAction Continue
}

$exitCode = 0
try {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'NCLogTools', 'NCLogTools.psd1'
    Import-Module -Name ([System.IO.Path]::GetFullPath($manifest)) -Force -ErrorAction Stop

    # フォルダは直下の .BIN に展開する。見つからないパスは知らせたうえで、残りを開く
    $targets = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $full = [System.IO.Path]::GetFullPath($p)
        if ([System.IO.Directory]::Exists($full)) {
            foreach ($f in [System.IO.Directory]::GetFiles($full) | Sort-Object) {
                if ([System.IO.Path]::GetExtension($f) -ieq '.bin') { $targets.Add($f) }
            }
        }
        elseif ([System.IO.File]::Exists($full)) {
            $targets.Add($full)
        }
        else {
            $missing.Add($full)
        }
    }
    if ($missing.Count -gt 0) {
        Show-NCLogLauncherError -Message ("次のファイルが見つかりません。`n`n" + ($missing -join "`n"))
    }

    if ($targets.Count -ge 1) {
        Show-NCLogViewer -LiteralPath $targets.ToArray() -ErrorAction Stop
    }
    else {
        Show-NCLogViewer -ErrorAction Stop
    }
}
catch {
    $exitCode = 1
    Show-NCLogLauncherError -Message "NCLog Viewer を起動できませんでした。`n`n$($_.Exception.Message)"
}

exit $exitCode
