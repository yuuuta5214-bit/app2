function Open-NCLogFile {
    <#
    .SYNOPSIS
        NCLog ファイルを読み取り専用・共有読み取りで開く。
    .DESCRIPTION
        ロガーが書き込み中のファイルでも読めるよう FileShare.ReadWrite で開く。
        呼び出し元は必ず finally で Dispose すること。
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)][string]$LiteralFilePath
    )

    [System.IO.FileStream]::new(
        $LiteralFilePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite,
        64KB,
        [System.IO.FileOptions]::SequentialScan)
}
