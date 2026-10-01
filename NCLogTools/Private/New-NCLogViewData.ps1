function New-NCLogViewData {
    <#
    .SYNOPSIS
        読み込んだバイト列を指定レイアウトで解析し、ビューアーが表示するデータ一式を作る。
    .DESCRIPTION
        ファイルを読み直さずにレイアウトだけ変えて再解析できるよう、バイト列を受け取る。
        レコードの扱いは Get-NCLogRecord と同じ:
        - 末尾の不完全なレコードは TrailingBytes として無視する
        - 値の形式は NCLogRecordFormat.ps1 の定義どおり
            Value40 = ADD_40_0: UInt16 (W)
            Value21 = ADD_21_0: Double を 1000 で割った値 (mm/min)
        - Value21 が NaN / ±Infinity なら無効レコード (統計・CSV の対象外)
        Plot40 / Plot21 はグラフ用で、無効値を直前の有効値 (先頭なら 0) で置き換えている。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'メモリ上にオブジェクトを作るだけで、システムの状態は変更しない')]
    [CmdletBinding()]
    [OutputType('NCLog.ViewData')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Path,
        [datetime]$LastWriteTime = [datetime]::MinValue,
        [Parameter(Mandatory)][int]$HeaderSize,
        [Parameter(Mandatory)][int]$RecordSize,
        [Parameter(Mandatory)][int]$Value40Offset,
        [Parameter(Mandatory)][int]$Value21Offset
    )

    if (-not [System.BitConverter]::IsLittleEndian) {
        throw [System.PlatformNotSupportedException]::new('ビッグエンディアン環境はサポートしていません。')
    }
    if ($RecordSize -le 0 -or $HeaderSize -lt 0) {
        throw [System.ArgumentException]::new('レコードレイアウトが不正です。')
    }
    $problem = Get-NCLogLayoutProblem -RecordSize $RecordSize -Value40Offset $Value40Offset -Value21Offset $Value21Offset
    if ($null -ne $problem) {
        throw [System.ArgumentException]::new("レコードレイアウトが不正です。$($problem.Message)")
    }

    $length = $Bytes.Length
    $dataLength = [Math]::Max(0, $length - $HeaderSize)
    $recordCount = [int][Math]::Floor($dataLength / $RecordSize)
    $trailing = $dataLength % $RecordSize

    $v40 = [double[]]::new($recordCount)
    $v21 = [double[]]::new($recordCount)
    $plot40 = [double[]]::new($recordCount)
    $plot21 = [double[]]::new($recordCount)
    $valid = [bool[]]::new($recordCount)
    $invalid = 0
    $last40 = 0.0
    $last21 = 0.0
    $divisor = $script:NCLogValue21Divisor

    for ($i = 0; $i -lt $recordCount; $i++) {
        $base = $HeaderSize + $i * $RecordSize
        $a = [double][System.BitConverter]::ToUInt16($Bytes, $base + $Value40Offset)
        $b = [System.BitConverter]::ToDouble($Bytes, $base + $Value21Offset) / $divisor
        $v40[$i] = $a
        $v21[$i] = $b
        # レーザー出力 (整数) は常に有効。ワイヤ速度が NaN / ±Infinity なら無効レコード
        if ([double]::IsFinite($b)) {
            $valid[$i] = $true
            $last40 = $a
            $last21 = $b
        }
        else {
            $invalid++
        }
        $plot40[$i] = $last40
        $plot21[$i] = $last21
    }

    $s40 = Measure-NCLogViewValue -Value $v40 -Valid $valid
    $s21 = Measure-NCLogViewValue -Value $v21 -Valid $valid
    $statistics = @(
        [pscustomobject]@{ Parameter = 'ADD_40_0'; Description = 'レーザー出力パワー'; Unit = 'W'
            Count = $s40.Count; Minimum = $s40.Minimum; Maximum = $s40.Maximum; Average = $s40.Average; StdDev = $s40.StdDev
        }
        [pscustomobject]@{ Parameter = 'ADD_21_0'; Description = 'ワイヤフィード速度'; Unit = 'mm/min'
            Count = $s21.Count; Minimum = $s21.Minimum; Maximum = $s21.Maximum; Average = $s21.Average; StdDev = $s21.StdDev
        }
    )

    # ヘッダーを 4 byte ごとに解釈 (レイアウト確認用。Get-NCLogFileInfo と同じ形式)
    $headerLength = [Math]::Min($HeaderSize, $length)
    $headerWords = @(
        for ($o = 0; $o + 4 -le $headerLength; $o += 4) {
            [pscustomobject]@{
                Offset = '0x{0:X4}' -f $o
                Hex    = [System.Convert]::ToHexString($Bytes, $o, 4)
                Int32  = [System.BitConverter]::ToInt32($Bytes, $o)
                Single = [System.BitConverter]::ToSingle($Bytes, $o)
            }
        }
    )

    [pscustomobject]@{
        PSTypeName    = 'NCLog.ViewData'
        Path          = $Path
        FileName      = [System.IO.Path]::GetFileName($Path)
        Length        = [long]$length
        LastWriteTime = $LastWriteTime
        Bytes         = $Bytes
        HeaderSize    = $HeaderSize
        RecordSize    = $RecordSize
        Value40Offset = $Value40Offset
        Value21Offset = $Value21Offset
        RecordCount   = $recordCount
        TrailingBytes = [int]$trailing
        InvalidCount  = $invalid
        Value40       = $v40
        Value21       = $v21
        Plot40        = $plot40
        Plot21        = $plot21
        Statistics    = $statistics
        HeaderWords   = $headerWords
    }
}
