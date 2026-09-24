<#
    テスト共通ヘルパー。各 *.Tests.ps1 の BeforeAll でドットソースする。
#>

function New-NCLogTestFile {
    <#
    .SYNOPSIS
        テスト用の NCLog バイナリファイルを生成する。
    .PARAMETER Path
        生成するファイルのパス。
    .PARAMETER Records
        @{ V40 = <single>; V21 = <single> } の配列。1要素が1レコード。
    .PARAMETER HeaderSize
        ヘッダーのバイト数 (0xAB で埋める)。
    .PARAMETER RecordSize
        レコードのバイト数。
    .PARAMETER Value40Offset
        ADD_40_0 のオフセット。
    .PARAMETER Value21Offset
        ADD_21_0 のオフセット。
    .PARAMETER TrailingBytes
        末尾に付ける端数バイト数。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'テスト専用。$TestDrive 内にのみファイルを作る')]
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][hashtable[]]$Records = @(),
        [int]$HeaderSize = 0x20,
        [int]$RecordSize = 16,
        [int]$Value40Offset = 4,
        [int]$Value21Offset = 8,
        [int]$TrailingBytes = 0
    )

    $bytes = [byte[]]::new($HeaderSize + $Records.Count * $RecordSize + $TrailingBytes)
    for ($h = 0; $h -lt $HeaderSize; $h++) { $bytes[$h] = 0xAB }

    for ($i = 0; $i -lt $Records.Count; $i++) {
        $base = $HeaderSize + $i * $RecordSize
        # レコード先頭にレコード番号 (Int32) を入れておく (Get-NCLogFileInfo の検証用)
        if ($RecordSize -ge 4 -and $Value40Offset -ge 4 -and $Value21Offset -ge 4) {
            [System.BitConverter]::GetBytes([int]$i).CopyTo($bytes, $base)
        }
        [System.BitConverter]::GetBytes([single]$Records[$i].V40).CopyTo($bytes, $base + $Value40Offset)
        [System.BitConverter]::GetBytes([single]$Records[$i].V21).CopyTo($bytes, $base + $Value21Offset)
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    [System.IO.File]::WriteAllBytes($full, $bytes)
    Get-Item -LiteralPath $full
}
