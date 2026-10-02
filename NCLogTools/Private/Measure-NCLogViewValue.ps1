function Measure-NCLogViewValue {
    <#
    .SYNOPSIS
        数値配列の統計 (件数・最小・最大・平均・母標準偏差) を計算する。
    .DESCRIPTION
        Valid が $true の要素だけを対象にする (Valid 省略時は有限値すべて)。
        Measure-NCLogRecord と同じく Welford 法で計算し、StdDev は母標準偏差 (n で割る)。
        対象が0件のときは Minimum 以降が $null。
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Value,
        [AllowEmptyCollection()][bool[]]$Valid
    )

    if ($PSBoundParameters.ContainsKey('Valid') -and $Valid.Length -ne $Value.Length) {
        throw [System.ArgumentException]::new('Value と Valid の件数が一致しません。')
    }
    $useMask = $PSBoundParameters.ContainsKey('Valid')

    if (Test-NCLogNative) {
        # 高速版 (C#)。結果は下の PowerShell 版と同じ
        # 配列は $( if ... ) や if 式で渡さないこと (パイプラインで1要素ずつ展開され、100 万件で約 1 秒かかる)
        $mask = $null
        if ($useMask) { $mask = $Valid }
        $s = [NCLogToolsNative.V1.RecordDecoder]::Measure($Value, $mask)
        if ($s.Count -eq 0) {
            return [pscustomobject]@{ Count = 0L; Minimum = $null; Maximum = $null; Average = $null; StdDev = $null }
        }
        return [pscustomobject]@{ Count = $s.Count; Minimum = $s.Minimum; Maximum = $s.Maximum; Average = $s.Average; StdDev = $s.StdDev }
    }

    $n = 0L
    $mean = 0.0
    $m2 = 0.0
    $min = [double]::PositiveInfinity
    $max = [double]::NegativeInfinity
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ($useMask) {
            if (-not $Valid[$i]) { continue }
        }
        elseif (-not [double]::IsFinite($Value[$i])) {
            continue
        }
        $x = [double]$Value[$i]
        $n++
        $delta = $x - $mean
        $mean += $delta / $n
        $m2 += $delta * ($x - $mean)
        if ($x -lt $min) { $min = $x }
        if ($x -gt $max) { $max = $x }
    }

    if ($n -eq 0) {
        return [pscustomobject]@{ Count = 0L; Minimum = $null; Maximum = $null; Average = $null; StdDev = $null }
    }
    [pscustomobject]@{
        Count   = $n
        Minimum = $min
        Maximum = $max
        Average = $mean
        StdDev  = [Math]::Sqrt($m2 / $n)
    }
}
