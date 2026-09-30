function Get-NCLogByteInterpretation {
    <#
    .SYNOPSIS
        指定オフセットのバイト列を各数値型 (リトルエンディアン) として解釈した一覧を返す。
    .DESCRIPTION
        16進ダンプで選んだ位置が、どの型なら意味のある値になるかを確認するためのもの。
        ファイル終端を越える型は Value が '(範囲外)' になる。
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][long]$Offset
    )

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $definitions = @(
        @{ Type = 'UInt8'; Size = 1; Read = { param($b, $o) $b[$o] } }
        @{ Type = 'Int8'; Size = 1; Read = { param($b, $o) if ($b[$o] -ge 0x80) { [int]$b[$o] - 0x100 } else { [int]$b[$o] } } }
        @{ Type = 'UInt16'; Size = 2; Read = { param($b, $o) [System.BitConverter]::ToUInt16($b, $o) } }
        @{ Type = 'Int16'; Size = 2; Read = { param($b, $o) [System.BitConverter]::ToInt16($b, $o) } }
        @{ Type = 'UInt32'; Size = 4; Read = { param($b, $o) [System.BitConverter]::ToUInt32($b, $o) } }
        @{ Type = 'Int32'; Size = 4; Read = { param($b, $o) [System.BitConverter]::ToInt32($b, $o) } }
        @{ Type = 'Single (float32)'; Size = 4; Read = { param($b, $o) [System.BitConverter]::ToSingle($b, $o).ToString('R', $ic) } }
        @{ Type = 'Int64'; Size = 8; Read = { param($b, $o) [System.BitConverter]::ToInt64($b, $o) } }
        @{ Type = 'Double (float64)'; Size = 8; Read = { param($b, $o) [System.BitConverter]::ToDouble($b, $o).ToString('R', $ic) } }
    )

    foreach ($d in $definitions) {
        $inRange = $Offset -ge 0 -and $Offset + $d.Size -le $Bytes.Length
        [pscustomobject]@{
            Type  = $d.Type
            Hex   = if ($inRange) { [System.Convert]::ToHexString($Bytes, [int]$Offset, $d.Size) } else { '' }
            Value = if ($inRange) { [string](& $d.Read $Bytes ([int]$Offset)) } else { '(範囲外)' }
        }
    }
}
