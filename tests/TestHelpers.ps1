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
        @{ V40 = <UInt16 の W>; V21 = <mm/min> } の配列。1要素が1レコード。
        実機の形式どおり、V40 は UInt16 (2 byte)、V21 は 1000 倍した Double (8 byte) で書き込む。
        V21 に NaN / Infinity を指定すると無効レコードになる。
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
        # 既定は実機ログのレイアウト (ヘッダーなし / 368 byte / +328 / +160)
        [int]$HeaderSize = 0,
        [int]$RecordSize = 368,
        [int]$Value40Offset = 328,
        [int]$Value21Offset = 160,
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
        [System.BitConverter]::GetBytes([uint16]$Records[$i].V40).CopyTo($bytes, $base + $Value40Offset)
        [System.BitConverter]::GetBytes([double]$Records[$i].V21 * 1000.0).CopyTo($bytes, $base + $Value21Offset)
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    [System.IO.File]::WriteAllBytes($full, $bytes)
    Get-Item -LiteralPath $full
}

# 以前の仮のレイアウト (ヘッダー 0x20 / 16 byte / +4 / +8)。レイアウト指定や16進表示など、
# 小さなデータで仕組みを確認するテストで使う:  New-NCLogTestFile ... @LegacyLayout
$script:LegacyLayout = @{ HeaderSize = 0x20; RecordSize = 16; Value40Offset = 4; Value21Offset = 8 }
