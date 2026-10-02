<#
    ビューアーで開いている1ファイル分の状態 (ファイル一覧の1行)。

    WPF の DataGrid (ファイル一覧) に直接バインドする。プロパティ変更の通知は持たないため、
    値を変えたら画面側で一覧を Items.Refresh() する。

    メモリ: 解析結果 (Data。バイト列と値の配列で 1 ファイル最大 約 60MB) は選択中のファイルだけが持つ。
    ほかのファイルは件数などの要約 (RecordCount / InvalidCount / Layout) だけを持ち、
    選択されたときに Import-NCLogViewerFileData でファイルを読み直す。
    多数のファイルを開いてもメモリを使い切って PC が固まらないようにするため。
#>

class NCLogViewerFile {
    # BIN ファイルの絶対パス
    [string]$Path
    [string]$FileName
    # New-NCLogViewData の結果 (バイト列を含む)。選択中のファイル以外は $null
    [object]$Data

    # 解析結果の要約 (Data を解放しても残す)
    [int]$RecordCount = 0
    [int]$InvalidCount = 0
    [datetime]$LastWriteTime = [datetime]::MinValue
    # 解析に使ったレイアウト (HeaderSize / RecordSize / Value40Offset / Value21Offset)
    [hashtable]$Layout

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
        $this.SetData($data)
    }

    # 解析結果を設定し、要約も更新する
    [void] SetData([object]$data) {
        $this.Data = $data
        $this.RecordCount = $data.RecordCount
        $this.InvalidCount = $data.InvalidCount
        $this.LastWriteTime = $data.LastWriteTime
        $this.Layout = @{
            HeaderSize    = [int]$data.HeaderSize
            RecordSize    = [int]$data.RecordSize
            Value40Offset = [int]$data.Value40Offset
            Value21Offset = [int]$data.Value21Offset
        }
        if ($this.PickedRecord -ge $this.RecordCount) { $this.PickedRecord = -1 }
    }

    # 解析結果を解放する (要約は残す)
    [void] ReleaseData() {
        $this.Data = $null
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

function Read-NCLogViewerFileData {
    <#
    .SYNOPSIS
        BIN ファイルを読み、指定のレイアウトで解析した結果 (New-NCLogViewData) を返す。
    .PARAMETER Layout
        HeaderSize / RecordSize / Value40Offset / Value21Offset を持つ hashtable。
    #>
    [CmdletBinding()]
    [OutputType('NCLog.ViewData')]
    param(
        [Parameter(Mandatory)][string]$LiteralFilePath,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $bytes = Read-NCLogViewFile -LiteralFilePath $LiteralFilePath
    New-NCLogViewData -Bytes $bytes -Path $LiteralFilePath -LastWriteTime ([System.IO.File]::GetLastWriteTime($LiteralFilePath)) `
        -HeaderSize $Layout.HeaderSize -RecordSize $Layout.RecordSize `
        -Value40Offset $Layout.Value40Offset -Value21Offset $Layout.Value21Offset
}

function Import-NCLogViewerFileData {
    <#
    .SYNOPSIS
        ファイル一覧の1ファイルの解析結果を用意する (なければファイルを読み直す)。
    .DESCRIPTION
        Data がなければ File.Layout (Layout 指定時はそれ) でファイルを読み直して解析する。
        Layout を指定した場合は、Data があっても指定のレイアウトで解析し直す (バイト列は読み直さない)。
    #>
    [CmdletBinding()]
    [OutputType('NCLog.ViewData')]
    param(
        [Parameter(Mandatory)][object]$File,
        [hashtable]$Layout
    )

    if ($null -ne $File.Data -and -not $Layout) { return $File.Data }

    $useLayout = if ($Layout) { $Layout } else { $File.Layout }
    $data = if ($null -ne $File.Data) {
        New-NCLogViewData -Bytes $File.Data.Bytes -Path $File.Path -LastWriteTime $File.Data.LastWriteTime @useLayout
    }
    else {
        Read-NCLogViewerFileData -LiteralFilePath $File.Path -Layout $useLayout
    }
    $File.SetData($data)
    $data
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

        if (($f.RecordCount - $f.InvalidCount) -le 0) {
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
