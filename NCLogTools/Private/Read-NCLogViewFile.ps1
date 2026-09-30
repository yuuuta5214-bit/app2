function Read-NCLogViewFile {
    <#
    .SYNOPSIS
        ビューアー用に NCLog ファイル全体をメモリへ読み込む。
    .DESCRIPTION
        読み取り専用・共有読み取り (Open-NCLogFile) で開き、全バイトを返す。
        メモリを使い過ぎないよう、MaxFileSize を超えるファイルは読まずに IOException とする。
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$LiteralFilePath,
        [ValidateRange(1, 1GB)][long]$MaxFileSize = 16MB
    )

    $stream = Open-NCLogFile -LiteralFilePath $LiteralFilePath
    try {
        $length = $stream.Length
        if ($length -gt $MaxFileSize) {
            throw [System.IO.IOException]::new(
                "ファイルが大きすぎます ($length byte)。ビューアーで開けるのは $MaxFileSize byte までです: $LiteralFilePath")
        }
        $bytes = [byte[]]::new($length)
        if ($length -gt 0) {
            Read-NCLogBlock -Stream $stream -Buffer $bytes -Count ([int]$length)
        }
        # byte[] がパイプラインで1要素ずつに展開されないよう、配列のまま返す
        , $bytes
    }
    finally {
        $stream.Dispose()
    }
}
