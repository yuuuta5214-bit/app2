<#
    ビューアーで開いている1ファイル分の状態 (ファイル一覧の1行)。

    WPF の DataGrid (ファイル一覧) に直接バインドする。プロパティ変更の通知は持たないため、
    値を変えたら画面側で一覧を Items.Refresh() する。
#>

class NCLogViewerFile {
    # BIN ファイルの絶対パス
    [string]$Path
    [string]$FileName
    # New-NCLogViewData の結果 (バイト列を含む。レイアウト変更時はこれを解析し直す)
    [object]$Data

    # 出力ファイル名の入力値 (画面の入力欄の文字列そのまま)
    [string]$LaserText = ''
    [string]$WireText = ''
    [string]$RatioText = ''
    # グラフから値を取得したレコード番号 (-1 = 未取得)
    [long]$PickedRecord = -1

    # Update-NCLogViewerFileState が計算する
    [string]$OutputName = ''
    [string]$OutputPath = ''
    [string]$Status = ''
    [bool]$IsReady = $false

    NCLogViewerFile([string]$path, [object]$data) {
        $this.Path = $path
        $this.FileName = [System.IO.Path]::GetFileName($path)
        $this.Data = $data
    }
}

function New-NCLogViewerFile {
    <#
    .SYNOPSIS
        ファイル一覧の1行 (NCLogViewerFile) を作る。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'メモリ上にオブジェクトを作るだけ')]
    [CmdletBinding()]
    [OutputType('NCLogViewerFile')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][psobject]$Data
    )

    [NCLogViewerFile]::new($Path, $Data)
}

function Update-NCLogViewerFileState {
    <#
    .SYNOPSIS
        各ファイルの入力値から出力ファイル名・出力先パス・状態を計算する。
    .DESCRIPTION
        - レーザー出力・ワイヤ速度・割合がすべて数値なら OutputName を作る (Get-NCLogCsvFileName)
        - OutputDirectory が空なら BIN と同じフォルダに出力する
        - 出力先パスが他のファイルと重複する場合 (大文字小文字は区別しない) は出力不可にする
        IsReady が $true のファイルだけが一括 CSV 出力の対象になる。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'メモリ上のオブジェクトの計算結果を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$File,
        [AllowEmptyString()][AllowNull()][string]$OutputDirectory
    )

    $directory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $null } else { $OutputDirectory.Trim() }

    foreach ($f in $File) {
        $f.OutputName = ''
        $f.OutputPath = ''
        $f.IsReady = $false

        $missing = [System.Collections.Generic.List[string]]::new()
        $values = @{}
        try {
            foreach ($item in @(
                    @{ Key = 'Laser'; Text = $f.LaserText; Label = 'レーザー出力'; Unit = @('W'); Negative = $true }
                    @{ Key = 'Wire'; Text = $f.WireText; Label = 'ワイヤ速度'; Unit = @('mm/min', 'mm-min'); Negative = $true }
                    @{ Key = 'Ratio'; Text = $f.RatioText; Label = '割合'; Unit = @('%'); Negative = $false }
                )) {
                $v = ConvertFrom-NCLogDecimalText -Text $item.Text -Name $item.Label -Unit $item.Unit -AllowNegative:$item.Negative
                if ($null -eq $v) { $missing.Add($item.Label) } else { $values[$item.Key] = $v }
            }
        }
        catch {
            $f.Status = $_.Exception.Message
            continue
        }

        if ($missing.Count -gt 0) {
            $f.Status = '未入力: ' + ($missing -join ' / ')
            continue
        }

        $f.OutputName = Get-NCLogCsvFileName -LaserPower $values.Laser -WireFeed $values.Wire -Ratio $values.Ratio
        # 出力先フォルダは入力途中でも呼ばれるため、不正な場合は例外にせず状態に表示する
        if ($directory -and -not [System.IO.Path]::IsPathRooted($directory)) {
            $f.Status = '出力先フォルダは絶対パスで指定してください'
            continue
        }
        $folder = if ($directory) { $directory } else { [System.IO.Path]::GetDirectoryName($f.Path) }
        try {
            $f.OutputPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($folder, $f.OutputName))
        }
        catch {
            $f.Status = "出力先フォルダが不正です: $folder"
            continue
        }

        if ($null -ne $f.Data -and ($f.Data.RecordCount - $f.Data.InvalidCount) -le 0) {
            $f.Status = '有効なレコードがありません'
            continue
        }
        $f.Status = '出力できます'
        $f.IsReady = $true
    }

    # 出力先の重複 (同じ CSV に上書きし合う) を検出する
    $groups = $File | Where-Object { $_.IsReady } |
        Group-Object -Property { $_.OutputPath.ToUpperInvariant() } | Where-Object Count -gt 1
    foreach ($group in $groups) {
        foreach ($f in $group.Group) {
            $f.IsReady = $false
            $f.Status = "出力ファイル名が重複しています ($($group.Count) 件)"
        }
    }
}
