function Resolve-NCLogViewerOpenTarget {
    <#
    .SYNOPSIS
        ビューアーで開くファイルの一覧を作る (ファイル選択・ドラッグ＆ドロップ・起動引数)。
    .DESCRIPTION
        - ファイルはそのまま、フォルダは直下の *.BIN (大文字小文字を区別しない) を名前順に追加する
        - 同じファイルの重複と、既に開いているファイル (Existing) は除く
        - MaxCount を超えた分は開かない
        パスはすべて絶対パスで返す。
    .OUTPUTS
        [pscustomobject] Files (開くファイル) / AlreadyOpen (既に開いているファイル) / Messages (開かなかった理由)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Path,
        [AllowEmptyCollection()][string[]]$Existing = @(),
        [ValidateRange(0, 10000)][int]$MaxCount = 100
    )

    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $open = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Existing | Where-Object { $_ }), $comparer)
    $files = [System.Collections.Generic.List[string]]::new()
    $already = [System.Collections.Generic.List[string]]::new()
    $messages = [System.Collections.Generic.List[string]]::new()
    $overflow = 0

    $candidates = foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $full = [System.IO.Path]::GetFullPath($p)
        if ([System.IO.Directory]::Exists($full)) {
            $found = @([System.IO.Directory]::GetFiles($full) |
                    Where-Object { [System.IO.Path]::GetExtension($_) -ieq '.bin' } |
                    Sort-Object)
            if ($found.Count -eq 0) { $messages.Add("フォルダに .BIN ファイルがありません: $full") }
            $found
        }
        elseif ([System.IO.File]::Exists($full)) {
            $full
        }
        else {
            $messages.Add("ファイルが見つかりません: $full")
        }
    }

    foreach ($c in $candidates) {
        if (-not $seen.Add($c)) { continue }
        if ($open.Contains($c)) { $already.Add($c); continue }
        if ($files.Count -ge $MaxCount) { $overflow++; continue }
        $files.Add($c)
    }
    if ($overflow -gt 0) {
        $messages.Add("一度に開けるのは $MaxCount ファイルまでです。$overflow ファイルは開きませんでした。")
    }

    [pscustomobject]@{
        Files       = [string[]]$files.ToArray()
        AlreadyOpen = [string[]]$already.ToArray()
        Messages    = [string[]]$messages.ToArray()
    }
}

function Get-NCLogChartIndex {
    <#
    .SYNOPSIS
        グラフ上の X 座標をレコード番号に変換する (Get-NCLogPlotGeometry と同じ対応)。
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][double]$X,
        [Parameter(Mandatory)][double]$Width,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$End,
        [Parameter(Mandatory)][int]$RecordCount
    )

    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, $X / [Math]::Max(1.0, $Width)))
    $index = [int][Math]::Round($Start + $ratio * ($End - $Start))
    [Math]::Min([Math]::Max(0, $index), [Math]::Max(0, $RecordCount - 1))
}

function Get-NCLogChartX {
    <#
    .SYNOPSIS
        レコード番号をグラフ上の X 座標に変換する。表示範囲外なら $null。
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][long]$Index,
        [Parameter(Mandatory)][double]$Width,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$End
    )

    if ($Index -lt $Start -or $Index -gt $End) { return $null }
    if ($End -le $Start) { return $Width / 2 }
    ($Index - $Start) / ($End - $Start) * $Width
}
