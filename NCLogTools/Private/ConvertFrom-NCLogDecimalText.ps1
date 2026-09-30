function ConvertFrom-NCLogDecimalText {
    <#
    .SYNOPSIS
        画面で入力された小数の文字列を double に変換する (CSV 出力ファイル名の値用)。
    .DESCRIPTION
        '50' / '12.5' / ' 2000 ' / '５０' (全角) / '50%' (末尾の単位) を受け付ける。
        全角の数字・記号は Unicode 正規化 (NFKC) で半角にしてから解釈する。
        空欄・空白だけの場合は $null を返す (未入力の扱いは呼び出し側で決める)。
        数値として解釈できない場合と、AllowNegative なしで負の値の場合は FormatException。
    .PARAMETER Unit
        末尾に付いていても無視する単位 ('%' / 'W' / 'mm/min' など)。大文字小文字は区別しない。
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text,
        [string]$Name = '値',
        [string[]]$Unit = @(),
        [switch]$AllowNegative
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $t = $Text.Normalize([System.Text.NormalizationForm]::FormKC).Trim()
    foreach ($u in $Unit) {
        if ($u -and $t.EndsWith($u, [System.StringComparison]::OrdinalIgnoreCase)) {
            $t = $t.Substring(0, $t.Length - $u.Length).TrimEnd()
            break
        }
    }

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $result = 0.0
    $ok = $t -match '^[+-]?([0-9]{1,12}(\.[0-9]{1,9})?|\.[0-9]{1,9})$' -and
        [double]::TryParse($t, [System.Globalization.NumberStyles]::AllowLeadingSign -bor
            [System.Globalization.NumberStyles]::AllowDecimalPoint, $ic, [ref]$result)

    if (-not $ok) {
        throw [System.FormatException]::new("$Name には数値 (例: 50 / 12.5) を入力してください: '$Text'")
    }
    if (-not $AllowNegative -and $result -lt 0) {
        throw [System.FormatException]::new("$Name には 0 以上の数値を入力してください: '$Text'")
    }
    $result
}
