function Format-NCLogFileNameValue {
    <#
    .SYNOPSIS
        ファイル名に入れる数値を文字列にする (小数第2位で四捨五入、末尾の 0 と小数点は省略)。
    .DESCRIPTION
        2000 → '2000' / 12.5 → '12.5' / 45.678 → '45.68' / -0.001 → '0'。
        カルチャに依存しないよう InvariantCulture で整形する (小数点は常に '.')。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][double]$Value
    )

    if (-not [double]::IsFinite($Value)) {
        throw [System.ArgumentException]::new("数値ではない値はファイル名に使えません: $Value")
    }
    $rounded = [Math]::Round($Value, 2, [System.MidpointRounding]::AwayFromZero)
    # -0.001 を丸めた -0 を '0' にする
    if ($rounded -eq 0) { $rounded = 0.0 }
    $rounded.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-NCLogCsvFileName {
    <#
    .SYNOPSIS
        CSV の出力ファイル名「レーザー出力W_ワイヤ速度mm-min_割合%.csv」を作る。
    .DESCRIPTION
        例: 2000 / 1000 / 50 → '2000W_1000mm-min_50%.csv'

        Windows のファイル名には '/' を使えないため、ワイヤ速度の単位 mm/min は 'mm-min' と書く。
        作った名前にファイル名として使えない文字が含まれていないことも確認する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][double]$LaserPower,
        [Parameter(Mandatory)][double]$WireFeed,
        [Parameter(Mandatory)][double]$Ratio
    )

    $name = '{0}W_{1}mm-min_{2}%.csv' -f (Format-NCLogFileNameValue -Value $LaserPower),
        (Format-NCLogFileNameValue -Value $WireFeed), (Format-NCLogFileNameValue -Value $Ratio)

    # 数値から作るため通常は起きないが、パス区切りなどが紛れ込まないことを保証する
    if ($name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.IndexOfAny([char[]]'\/:*?"<>|') -ge 0) {
        throw [System.ArgumentException]::new("ファイル名に使えない文字が含まれています: $name")
    }
    $name
}
