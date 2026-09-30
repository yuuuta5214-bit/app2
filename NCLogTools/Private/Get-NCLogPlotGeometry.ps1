function Get-NCLogPlotGeometry {
    <#
    .SYNOPSIS
        折れ線グラフの頂点座標 (WPF の PointCollection 文字列) を計算する。
    .DESCRIPTION
        Value[Start..End] を Width x Height の領域に描く座標を "x,y x,y ..." 形式
        (InvariantCulture) で返す。WPF 側は [System.Windows.Media.PointCollection]::Parse で使う。

        点の数が横ピクセル数の2倍を超える場合は、1ピクセル列ごとに最小値と最大値の2点だけを残す
        (min/max 間引き)。スパイクを見落とさずに、頂点数を画面幅程度に抑えられる。

        Value は有限値である必要がある (New-NCLogViewData の Plot40 / Plot21 を渡す)。
        Minimum / Maximum を省略すると表示範囲の最小・最大値を使い、上下に Margin (範囲に対する比率) の余白を足す。
        Y 軸は上が大きい値。最小と最大が同じ場合は中央に水平線を描く。
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][float[]]$Value,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$End,
        [Parameter(Mandatory)][ValidateRange(1, 100000)][double]$Width,
        [Parameter(Mandatory)][ValidateRange(1, 100000)][double]$Height,
        [Nullable[double]]$Minimum,
        [Nullable[double]]$Maximum,
        [ValidateRange(0, 1)][double]$Margin = 0
    )

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $empty = [pscustomobject]@{ Points = ''; Minimum = 0.0; Maximum = 0.0; Start = $Start; End = $End; PointCount = 0 }

    if ($Value.Length -eq 0) { return $empty }
    $Start = [Math]::Max(0, [Math]::Min($Start, $Value.Length - 1))
    $End = [Math]::Max(0, [Math]::Min($End, $Value.Length - 1))
    if ($End -lt $Start) { return $empty }

    $n = $End - $Start + 1
    $segment = [System.ArraySegment[float]]::new($Value, $Start, $n)
    $min = if ($null -ne $Minimum) { [double]$Minimum } else { [double][System.Linq.Enumerable]::Min($segment) }
    $max = if ($null -ne $Maximum) { [double]$Maximum } else { [double][System.Linq.Enumerable]::Max($segment) }
    $span = $max - $min
    if ($span -gt 0 -and $Margin -gt 0) {
        if ($null -eq $Minimum) { $min -= $span * $Margin }
        if ($null -eq $Maximum) { $max += $span * $Margin }
        $span = $max - $min
    }

    # 値 → Y 座標 (上端 0): y = Height - (v - min) * scale。最小 = 最大なら中央の水平線
    $scale = if ($span -gt 0) { $Height / $span } else { 0.0 }
    $flatY = $Height / 2

    # 頂点ごとにスクリプトブロックを呼ぶと 1 回数十 us かかるため、計算はループ内に展開する
    $xs = [System.Collections.Generic.List[double]]::new()
    $ys = [System.Collections.Generic.List[double]]::new()
    $columns = [int][Math]::Max(1, [Math]::Floor($Width))
    if ($n -eq 1) {
        # 1点だけなら左端から右端への水平線
        $y = if ($scale -gt 0) { $Height - ($Value[$Start] - $min) * $scale } else { $flatY }
        $xs.Add(0); $ys.Add($y)
        $xs.Add($Width); $ys.Add($y)
    }
    elseif ($n -le 2 * $columns) {
        # 間引き不要: 全点を描く
        $step = $Width / ($n - 1)
        for ($i = 0; $i -lt $n; $i++) {
            $xs.Add($i * $step)
            $ys.Add($(if ($scale -gt 0) { $Height - ($Value[$Start + $i] - $min) * $scale } else { $flatY }))
        }
    }
    else {
        for ($c = 0; $c -lt $columns; $c++) {
            $s = [int][Math]::Floor([double]$c * $n / $columns)
            $e = [int][Math]::Floor([double]($c + 1) * $n / $columns)
            $bucket = [System.ArraySegment[float]]::new($Value, $Start + $s, [Math]::Max(1, $e - $s))
            $x = ($c + 0.5) / $columns * $Width
            $lo = [System.Linq.Enumerable]::Min($bucket)
            $hi = [System.Linq.Enumerable]::Max($bucket)
            $xs.Add($x); $ys.Add($(if ($scale -gt 0) { $Height - ($lo - $min) * $scale } else { $flatY }))
            $xs.Add($x); $ys.Add($(if ($scale -gt 0) { $Height - ($hi - $min) * $scale } else { $flatY }))
        }
    }

    $parts = [string[]]::new($xs.Count)
    for ($i = 0; $i -lt $xs.Count; $i++) {
        $parts[$i] = [string]::Format($ic, '{0:0.##},{1:0.##}', $xs[$i], $ys[$i])
    }

    [pscustomobject]@{
        Points     = [string]::Join(' ', $parts)
        Minimum    = $min
        Maximum    = $max
        Start      = $Start
        End        = $End
        PointCount = $parts.Length
    }
}
