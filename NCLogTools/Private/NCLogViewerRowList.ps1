<#
    ビューアーの表 (16進ダンプ / レコード表) に渡す遅延生成リスト。

    WPF の DataGrid は行の仮想化により、画面に見えている行のインデックスだけを IList の
    インデクサーで要求する。行オブジェクトをその場で作ることで、ファイル全体の行を
    事前に作らずに済み (1MB で約 6.5 万行)、ファイルを開いた直後から表示できる。

    - 行はインデックスが同じなら Equals で等しい (WPF の選択・ScrollIntoView が再生成した行でも一致する)
    - リストは読み取り専用。変更系のメソッドは NotSupportedException
    - リストを関数から返すときは列挙されないよう Write-Output -NoEnumerate を使うこと
#>

class NCLogViewRow {
    # 0 始まりの行インデックス
    [int]$Index

    [bool] Equals([object]$other) {
        return ($null -ne $other) -and ($other.GetType() -eq $this.GetType()) -and ($other.Index -eq $this.Index)
    }

    [int] GetHashCode() {
        return $this.Index
    }
}

class NCLogHexRow : NCLogViewRow {
    [long]$Offset
    [string]$Address
    # 行先頭バイトの領域: Header / Even / Odd (レコード番号の偶奇) / Trailing
    [string]$Band
    # 行先頭バイトが属するレコード番号 (ヘッダー・端数は空)
    [string]$Record
    # 16 byte 分の16進文字列 (XAML から Hex[0]～Hex[15] でバインド)。ファイル終端を越える位置は空文字
    [string[]]$Hex
    [string]$Ascii
}

class NCLogRecordRow : NCLogViewRow {
    [long]$RecordNumber
    [long]$Offset
    [string]$Address
    [double]$Value40
    [double]$Value21
    [bool]$IsValid
}

class NCLogViewRowList : System.Collections.IList {
    hidden [int]$RowCount

    NCLogViewRowList([int]$rowCount) {
        $this.RowCount = $rowCount
    }

    # 派生クラスで実装する
    [object] CreateRow([int]$index) {
        throw [System.NotImplementedException]::new('CreateRow')
    }

    [object] get_Item([int]$index) {
        if ($index -lt 0 -or $index -ge $this.RowCount) {
            throw [System.ArgumentOutOfRangeException]::new('index', $index, "0 から $($this.RowCount - 1) の範囲で指定してください。")
        }
        return $this.CreateRow($index)
    }

    [void] set_Item([int]$index, [object]$value) {
        throw [System.NotSupportedException]::new('読み取り専用のリストです。')
    }

    [bool] get_IsFixedSize() { return $true }
    [bool] get_IsReadOnly() { return $true }
    [int] get_Count() { return $this.RowCount }
    [bool] get_IsSynchronized() { return $false }
    [object] get_SyncRoot() { return $this }

    [int] IndexOf([object]$value) {
        if ($value -is [NCLogViewRow] -and $value.Index -ge 0 -and $value.Index -lt $this.RowCount -and
            $this.CreateRow($value.Index).Equals($value)) {
            return $value.Index
        }
        return -1
    }

    [bool] Contains([object]$value) {
        return $this.IndexOf($value) -ge 0
    }

    [void] CopyTo([System.Array]$array, [int]$index) {
        for ($i = 0; $i -lt $this.RowCount; $i++) {
            $array.SetValue($this.CreateRow($i), $index + $i)
        }
    }

    [System.Collections.IEnumerator] GetEnumerator() {
        # 全行を作るので UI からは使われない (ソート無効の DataGrid はインデクサーのみ使う)
        $all = [object[]]::new($this.RowCount)
        $this.CopyTo($all, 0)
        return $all.GetEnumerator()
    }

    [int] Add([object]$value) { throw [System.NotSupportedException]::new('読み取り専用のリストです。') }
    [void] Clear() { throw [System.NotSupportedException]::new('読み取り専用のリストです。') }
    [void] Insert([int]$index, [object]$value) { throw [System.NotSupportedException]::new('読み取り専用のリストです。') }
    [void] Remove([object]$value) { throw [System.NotSupportedException]::new('読み取り専用のリストです。') }
    [void] RemoveAt([int]$index) { throw [System.NotSupportedException]::new('読み取り専用のリストです。') }
}

class NCLogHexRowList : NCLogViewRowList {
    hidden [byte[]]$Bytes
    hidden [int]$HeaderSize
    hidden [int]$RecordSize
    hidden [long]$DataEnd

    NCLogHexRowList([byte[]]$bytes, [int]$headerSize, [int]$recordSize, [long]$recordCount) : base([int][Math]::Ceiling($bytes.Length / 16.0)) {
        $this.Bytes = $bytes
        $this.HeaderSize = $headerSize
        $this.RecordSize = $recordSize
        $this.DataEnd = [Math]::Min($bytes.Length, $headerSize + $recordCount * $recordSize)
    }

    [object] CreateRow([int]$index) {
        $offset = [long]$index * 16
        $row = [NCLogHexRow]::new()
        $row.Index = $index
        $row.Offset = $offset
        $row.Address = $offset.ToString('X8')

        if ($offset -lt $this.HeaderSize) {
            $row.Band = 'Header'
            $row.Record = ''
        }
        elseif ($offset -ge $this.DataEnd) {
            $row.Band = 'Trailing'
            $row.Record = ''
        }
        else {
            $recordNumber = [long][Math]::Floor(($offset - $this.HeaderSize) / $this.RecordSize)
            $row.Band = if ($recordNumber % 2 -eq 0) { 'Even' } else { 'Odd' }
            $row.Record = $recordNumber.ToString()
        }

        $count = [int][Math]::Min(16, $this.Bytes.Length - $offset)
        $hexText = [string[]]::new(16)
        $ascii = [char[]]::new($count)
        for ($i = 0; $i -lt 16; $i++) {
            if ($i -ge $count) {
                $hexText[$i] = ''
                continue
            }
            $b = $this.Bytes[$offset + $i]
            $hexText[$i] = $b.ToString('X2')
            # 表示できる ASCII (0x20-0x7E) 以外は '.'
            $ascii[$i] = if ($b -ge 0x20 -and $b -le 0x7E) { [char]$b } else { '.' }
        }
        $row.Hex = $hexText
        $row.Ascii = [string]::new($ascii)
        return $row
    }
}

class NCLogRecordRowList : NCLogViewRowList {
    hidden [double[]]$Value40
    hidden [double[]]$Value21
    hidden [int]$HeaderSize
    hidden [int]$RecordSize

    NCLogRecordRowList([double[]]$value40, [double[]]$value21, [int]$headerSize, [int]$recordSize) : base($value40.Length) {
        $this.Value40 = $value40
        $this.Value21 = $value21
        $this.HeaderSize = $headerSize
        $this.RecordSize = $recordSize
    }

    [object] CreateRow([int]$index) {
        $row = [NCLogRecordRow]::new()
        $row.Index = $index
        $row.RecordNumber = $index
        $row.Offset = $this.HeaderSize + [long]$index * $this.RecordSize
        $row.Address = $row.Offset.ToString('X8')
        $row.Value40 = $this.Value40[$index]
        $row.Value21 = $this.Value21[$index]
        $row.IsValid = [double]::IsFinite($row.Value40) -and [double]::IsFinite($row.Value21)
        return $row
    }
}

function New-NCLogHexRowList {
    <#
    .SYNOPSIS
        16進ダンプ用の遅延生成リスト (1行 16 byte) を作る。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'メモリ上にオブジェクトを作るだけで、システムの状態は変更しない')]
    [CmdletBinding()]
    [OutputType([System.Collections.IList])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$HeaderSize,
        [Parameter(Mandatory)][int]$RecordSize,
        [Parameter(Mandatory)][long]$RecordCount
    )

    # IList はパイプラインで展開されるため、リストのまま返す
    Write-Output -NoEnumerate -InputObject ([NCLogHexRowList]::new($Bytes, $HeaderSize, $RecordSize, $RecordCount))
}

function New-NCLogRecordRowList {
    <#
    .SYNOPSIS
        レコード表用の遅延生成リストを作る。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'メモリ上にオブジェクトを作るだけで、システムの状態は変更しない')]
    [CmdletBinding()]
    [OutputType([System.Collections.IList])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Value40,
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Value21,
        [Parameter(Mandatory)][int]$HeaderSize,
        [Parameter(Mandatory)][int]$RecordSize
    )

    if ($Value40.Length -ne $Value21.Length) {
        throw [System.ArgumentException]::new('Value40 と Value21 の件数が一致しません。')
    }
    Write-Output -NoEnumerate -InputObject ([NCLogRecordRowList]::new($Value40, $Value21, $HeaderSize, $RecordSize))
}
