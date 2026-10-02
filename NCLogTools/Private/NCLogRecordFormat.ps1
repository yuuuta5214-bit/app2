<#
    NCLog レコード内の値の形式 (実機ログの仕様)。読み出しはすべてこの定義に従う。

        ADD_40_0 (レーザー出力)     : UInt16 リトルエンディアン 2 byte。値はそのまま W
        ADD_21_0 (ワイヤフィード速度): Double リトルエンディアン 8 byte。1000 で割った値が mm/min

    レーザー出力は整数なので常に有効。ワイヤ速度が NaN / ±Infinity のレコードは無効レコードとする。
    Get-NCLogRecord・ビューアーはループ内で BitConverter を直接呼ぶ (1レコードごとの関数呼び出しは遅いため)。
    形式を変えるときは、この定義と ToUInt16 / ToDouble を使っている箇所をあわせて変更すること。
#>

# ADD_40_0 のバイト数 (UInt16)
$script:NCLogValue40Size = 2
# ADD_21_0 のバイト数 (Double)
$script:NCLogValue21Size = 8
# ADD_21_0 の生の値をこの値で割ると mm/min になる
$script:NCLogValue21Divisor = 1000.0

function Get-NCLogLayoutProblem {
    <#
    .SYNOPSIS
        レコードレイアウトの問題を日本語メッセージで返す。問題がなければ $null。
    .DESCRIPTION
        - ADD_40_0 (2 byte) と ADD_21_0 (8 byte) がレコード内に収まること
        - 2つの値の領域が重ならないこと
        を確認する。Assert-NCLogLayout (コマンド) と Resolve-NCLogViewerLayout (画面) で共通に使う。
    .OUTPUTS
        [pscustomobject] Name (問題のあるパラメーター名) / Message。問題がなければ何も返さない
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$RecordSize,
        [Parameter(Mandatory)][int]$Value40Offset,
        [Parameter(Mandatory)][int]$Value21Offset
    )

    foreach ($entry in @(
            @{ Name = 'Value40Offset'; Offset = $Value40Offset; Size = $script:NCLogValue40Size; Label = 'ADD_40_0 (UInt16)' }
            @{ Name = 'Value21Offset'; Offset = $Value21Offset; Size = $script:NCLogValue21Size; Label = 'ADD_21_0 (Double)' }
        )) {
        if ($entry.Offset -lt 0 -or $entry.Offset + $entry.Size -gt $RecordSize) {
            return [pscustomobject]@{
                Name    = $entry.Name
                Message = "$($entry.Label) の位置 $($entry.Offset) + $($entry.Size) byte がレコードサイズ $RecordSize を超えています。"
            }
        }
    }

    $end40 = $Value40Offset + $script:NCLogValue40Size
    $end21 = $Value21Offset + $script:NCLogValue21Size
    if ($Value40Offset -lt $end21 -and $Value21Offset -lt $end40) {
        return [pscustomobject]@{
            Name    = 'Value21Offset'
            Message = "ADD_40_0 (+$Value40Offset～+$($end40 - 1)) と ADD_21_0 (+$Value21Offset～+$($end21 - 1)) の位置が重なっています。"
        }
    }
}
