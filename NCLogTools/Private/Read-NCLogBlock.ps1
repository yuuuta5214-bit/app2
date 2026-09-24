function Read-NCLogBlock {
    <#
    .SYNOPSIS
        ストリームから指定バイト数を確実に読み込む。
    .DESCRIPTION
        Stream.Read は要求より少ないバイト数を返すことがあるため、揃うまで繰り返す。
        途中でファイル終端に達した場合 (読み取り中に切り詰められた等) は EndOfStreamException。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][int]$Count
    )

    $filled = 0
    while ($filled -lt $Count) {
        $n = $Stream.Read($Buffer, $filled, $Count - $filled)
        if ($n -le 0) {
            throw [System.IO.EndOfStreamException]::new(
                "ファイルが途中で終了しました (期待 $Count byte / 取得 $filled byte)。読み取り中に切り詰められた可能性があります。")
        }
        $filled += $n
    }
}
