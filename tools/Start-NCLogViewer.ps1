#Requires -Version 7.2

<#
.SYNOPSIS
    NCLog Viewer の起動用スクリプト (NCLogViewer.cmd から起動)。

.DESCRIPTION
    NCLogTools モジュールを読み込み、Show-NCLogViewer でビューアーを表示します。

    - 引数なし      : 空のビューアーを表示します ([開く] またはドラッグ＆ドロップでファイルを指定)。
    - ファイル指定  : そのファイルを開きます。複数指定された場合は先頭の1ファイルだけを開きます。

    コンソールは非表示で起動されるため、エラーはメッセージボックスで表示します。

.PARAMETER Path
    開く NCLog ファイル。ワイルドカードとして解釈しません。
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

    $targets = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($targets.Count -gt 1) {
        Write-Warning "一度に開けるのは1ファイルです。先頭のファイルを開きます: $($targets[0])"
    }

    if ($targets.Count -ge 1) {
        Show-NCLogViewer -LiteralPath $targets[0] -ErrorAction Stop
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
