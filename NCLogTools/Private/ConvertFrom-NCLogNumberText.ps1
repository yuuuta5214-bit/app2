function ConvertFrom-NCLogNumberText {
    <#
    .SYNOPSIS
        画面で入力された数値文字列 (10進 または 0x 付き16進) を long に変換する。
    .DESCRIPTION
        '32' / '0x20' / '0X20' / ' 20h ' (末尾 h も16進) を受け付ける。
        数値として解釈できない場合は FormatException。
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Name = '値'
    )

    $t = $Text.Trim()
    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $result = 0L
    $ok = if ($t -match '^0[xX]([0-9A-Fa-f]{1,15})$' -or $t -match '^([0-9A-Fa-f]{1,15})[hH]$') {
        [long]::TryParse($Matches[1], [System.Globalization.NumberStyles]::AllowHexSpecifier, $ic, [ref]$result)
    }
    elseif ($t -match '^[0-9]{1,18}$') {
        [long]::TryParse($t, [System.Globalization.NumberStyles]::None, $ic, [ref]$result)
    }
    else {
        $false
    }

    if (-not $ok) {
        throw [System.FormatException]::new("$Name には 0 以上の整数 (10進、または 0x20 のような16進) を入力してください: '$Text'")
    }
    $result
}
