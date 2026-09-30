#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# ビューアーの画面に依存しない内部関数 (Private) のテスト。全 OS で実行する。

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    $script:log = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_viewer.BIN') -TrailingBytes 5 -Records @(
        @{ V40 = 10; V21 = 1000 }
        @{ V40 = [single]::NaN; V21 = 2000 }
        @{ V40 = 30; V21 = 3000 }
        @{ V40 = 20; V21 = [single]::PositiveInfinity }
    )
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Read-NCLogViewFile' {
    It 'ファイル全体を byte[] で返す' {
        $bytes = InModuleScope NCLogTools -Parameters @{ Path = $log.FullName } {
            param($Path)
            , (Read-NCLogViewFile -LiteralFilePath $Path)
        }
        $bytes.GetType() | Should -Be ([byte[]])
        $bytes.Length | Should -Be (0x20 + 4 * 16 + 5)
        $bytes[0] | Should -Be 0xAB
    }

    It '空ファイルは長さ 0 の配列' {
        $empty = Join-Path $TestDrive 'empty.BIN'
        [System.IO.File]::WriteAllBytes($empty, [byte[]]::new(0))
        $bytes = InModuleScope NCLogTools -Parameters @{ Path = $empty } {
            param($Path)
            , (Read-NCLogViewFile -LiteralFilePath $Path)
        }
        $bytes.Length | Should -Be 0
    }

    It 'MaxFileSize を超えるファイルは読まずに IOException' {
        { InModuleScope NCLogTools -Parameters @{ Path = $log.FullName } {
                param($Path)
                Read-NCLogViewFile -LiteralFilePath $Path -MaxFileSize 10
            } } | Should -Throw -ExceptionType ([System.IO.IOException]) -ExpectedMessage '*大きすぎます*'
    }
}

Describe 'New-NCLogViewData' {
    BeforeAll {
        $script:data = InModuleScope NCLogTools -Parameters @{ Path = $log.FullName } {
            param($Path)
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            New-NCLogViewData -Bytes $bytes -Path $Path -HeaderSize 0x20 -RecordSize 16 -Value40Offset 4 -Value21Offset 8
        }
    }

    It 'レコード数・端数・無効レコード数' {
        $data.PSObject.TypeNames | Should -Contain 'NCLog.ViewData'
        $data.FileName | Should -Be 'NCLog_viewer.BIN'
        $data.RecordCount | Should -Be 4
        $data.TrailingBytes | Should -Be 5
        $data.InvalidCount | Should -Be 2
    }

    It '値はそのまま保持する (無効値も含む)' {
        $data.Value40[0] | Should -Be 10
        [single]::IsNaN($data.Value40[1]) | Should -BeTrue
        [single]::IsPositiveInfinity($data.Value21[3]) | Should -BeTrue
    }

    It 'グラフ用の値は無効レコードを直前の有効値で置き換える' {
        $data.Plot40 | Should -Be @(10, 10, 30, 30)
        $data.Plot21 | Should -Be @(1000, 1000, 3000, 3000)
    }

    It '統計は有効レコード (両方の値が有限) のみ。Measure-NCLogRecord と一致する' {
        $s40 = $data.Statistics | Where-Object Parameter -EQ 'ADD_40_0'
        $s40.Count | Should -Be 2
        $s40.Minimum | Should -Be 10
        $s40.Maximum | Should -Be 30
        $s40.Average | Should -Be 20
        $s40.StdDev | Should -Be 10

        $expected = Get-NCLogRecord -LiteralPath $log.FullName -WarningAction SilentlyContinue | Measure-NCLogRecord
        foreach ($e in $expected) {
            $actual = $data.Statistics | Where-Object Parameter -EQ $e.Parameter
            $actual.Count | Should -Be $e.Count
            $actual.Average | Should -BeGreaterOrEqual ($e.Average - 1e-9)
            $actual.Average | Should -BeLessOrEqual ($e.Average + 1e-9)
            $actual.StdDev | Should -BeGreaterOrEqual ($e.StdDev - 1e-9)
            $actual.StdDev | Should -BeLessOrEqual ($e.StdDev + 1e-9)
        }
    }

    It 'ヘッダーを 4 byte ごとに解釈する' {
        $data.HeaderWords.Count | Should -Be 8
        $data.HeaderWords[1].Offset | Should -Be '0x0004'
        $data.HeaderWords[0].Hex | Should -Be 'ABABABAB'
    }

    It 'ヘッダーより短いデータでも失敗しない' {
        $tiny = InModuleScope NCLogTools {
            New-NCLogViewData -Bytes ([byte[]](1, 2, 3, 4, 5, 6)) -Path 'x.BIN' -HeaderSize 0x20 -RecordSize 16 -Value40Offset 4 -Value21Offset 8
        }
        $tiny.RecordCount | Should -Be 0
        $tiny.TrailingBytes | Should -Be 0
        $tiny.HeaderWords.Count | Should -Be 1
        $tiny.Statistics[0].Count | Should -Be 0
        $tiny.Statistics[0].Minimum | Should -BeNullOrEmpty
    }

    It '別のレイアウトで解析し直せる' {
        $other = InModuleScope NCLogTools -Parameters @{ Path = $log.FullName } {
            param($Path)
            New-NCLogViewData -Bytes ([System.IO.File]::ReadAllBytes($Path)) -Path $Path -HeaderSize 0x20 -RecordSize 32 -Value40Offset 4 -Value21Offset 24
        }
        $other.RecordCount | Should -Be 2
        $other.TrailingBytes | Should -Be 5
        $other.Value40[1] | Should -Be 30
        $other.Value21[0] | Should -Be 2000
    }

    It '不正なレイアウトは ArgumentException' {
        { InModuleScope NCLogTools {
                New-NCLogViewData -Bytes ([byte[]]::new(64)) -Path 'x.BIN' -HeaderSize 0 -RecordSize 8 -Value40Offset 6 -Value21Offset 0
            } } | Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'Measure-NCLogViewValue' {
    It 'Valid 省略時は有限値のみを対象にする' {
        $r = InModuleScope NCLogTools { Measure-NCLogViewValue -Value ([float[]](1, [single]::NaN, 3)) }
        $r.Count | Should -Be 2
        $r.Average | Should -Be 2
        $r.StdDev | Should -Be 1
    }

    It '0件なら値は $null' {
        $r = InModuleScope NCLogTools { Measure-NCLogViewValue -Value ([float[]]@()) }
        $r.Count | Should -Be 0
        $r.Average | Should -BeNullOrEmpty
    }

    It 'Value と Valid の件数が違えば例外' {
        { InModuleScope NCLogTools { Measure-NCLogViewValue -Value ([float[]](1, 2)) -Valid ([bool[]]@($true)) } } |
            Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'New-NCLogHexRowList' {
    BeforeAll {
        $script:hex = InModuleScope NCLogTools -Parameters @{ Path = $log.FullName } {
            param($Path)
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            New-NCLogHexRowList -Bytes $bytes -HeaderSize 0x20 -RecordSize 16 -RecordCount 4
        }
    }

    It '1行 16 byte の IList (読み取り専用)' {
        $hex -is [System.Collections.IList] | Should -BeTrue
        $hex.Count | Should -Be 7            # (0x20 + 64 + 5) / 16 の切り上げ
        $hex.IsReadOnly | Should -BeTrue
        $hex.IsFixedSize | Should -BeTrue
    }

    It 'ヘッダー行' {
        $row = $hex[0]
        $row.Address | Should -Be '00000000'
        $row.Band | Should -Be 'Header'
        $row.Record | Should -Be ''
        $row.Hex.Count | Should -Be 16
        $row.Hex[0] | Should -Be 'AB'
        $row.Ascii | Should -Be ('.' * 16)
    }

    It 'レコード行はレコード番号の偶奇で色分けする' {
        $hex[2].Band | Should -Be 'Even'
        $hex[2].Record | Should -Be '0'
        $hex[3].Band | Should -Be 'Odd'
        $hex[3].Record | Should -Be '1'
        $hex[3].Offset | Should -Be 0x30
        $hex[3].Hex[0] | Should -Be '01'   # レコード先頭のレコード番号 (Int32)
    }

    It '末尾の端数行は Trailing。ファイル終端より先は空文字' {
        $last = $hex[6]
        $last.Band | Should -Be 'Trailing'
        $last.Hex[4] | Should -Be '00'
        $last.Hex[5] | Should -Be ''
        $last.Ascii.Length | Should -Be 5
    }

    It '表示できない文字は . にする' {
        $row = InModuleScope NCLogTools {
            (New-NCLogHexRowList -Bytes ([System.Text.Encoding]::ASCII.GetBytes("AB`tz~")) -HeaderSize 0 -RecordSize 16 -RecordCount 0)[0]
        }
        $row.Ascii | Should -Be 'AB.z~'
    }

    It '同じインデックスの行は Equals で等しく、IndexOf で位置を返す' {
        $hex[4].Equals($hex[4]) | Should -BeTrue
        $hex[4].Equals($hex[5]) | Should -BeFalse
        $hex.IndexOf($hex[5]) | Should -Be 5
        $hex.Contains($hex[1]) | Should -BeTrue
        $hex.IndexOf('x') | Should -Be -1
    }

    It '範囲外のインデックスは例外 (WPF が使う IList のインデクサー)' {
        { $hex.get_Item(7) } | Should -Throw -ExpectedMessage '*範囲で指定*'
        { $hex.get_Item(-1) } | Should -Throw
    }

    It '変更系の操作は NotSupportedException' {
        { $hex.Add($hex[0]) } | Should -Throw -ExceptionType ([System.NotSupportedException])
        { $hex.RemoveAt(0) } | Should -Throw
        { $hex.Clear() } | Should -Throw
        { $hex.Insert(0, $null) } | Should -Throw
        { $hex.Remove($null) } | Should -Throw
        { $hex[0] = $null } | Should -Throw
    }

    It '列挙・CopyTo で全行を得られる' {
        @($hex).Count | Should -Be 7
        $array = [object[]]::new(8)
        $hex.CopyTo($array, 1)
        $array[7].Band | Should -Be 'Trailing'
        $hex.IsSynchronized | Should -BeFalse
        $hex.SyncRoot | Should -Not -BeNullOrEmpty
    }
}

Describe 'New-NCLogRecordRowList' {
    It 'レコード番号・アドレス・値・有効フラグを返す' {
        $list = InModuleScope NCLogTools {
            New-NCLogRecordRowList -Value40 ([float[]](1.5, [single]::NaN)) -Value21 ([float[]](10, 20)) -HeaderSize 0x20 -RecordSize 16
        }
        $list.Count | Should -Be 2
        $list[0].RecordNumber | Should -Be 0
        $list[0].Address | Should -Be '00000020'
        $list[0].Value40 | Should -Be 1.5
        $list[0].IsValid | Should -BeTrue
        $list[1].Offset | Should -Be 0x30
        $list[1].IsValid | Should -BeFalse
    }

    It '件数が違えば例外' {
        { InModuleScope NCLogTools {
                New-NCLogRecordRowList -Value40 ([float[]](1)) -Value21 ([float[]](1, 2)) -HeaderSize 0 -RecordSize 16
            } } | Should -Throw -ExpectedMessage '*一致しません*'
    }
}

Describe 'Get-NCLogPlotGeometry' {
    It '点数が少なければ全点を描く (上が最大値)' {
        $g = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]](0, 5, 10)) -Start 0 -End 2 -Width 100 -Height 50 }
        $g.Points | Should -Be '0,50 50,25 100,0'
        $g.Minimum | Should -Be 0
        $g.Maximum | Should -Be 10
        $g.PointCount | Should -Be 3
    }

    It '点数が多ければ 1 ピクセル列ごとに最小・最大の2点に間引く (スパイクを残す)' {
        $g = InModuleScope NCLogTools {
            $v = [float[]]::new(10000)
            $v[5000] = 100
            Get-NCLogPlotGeometry -Value $v -Start 0 -End 9999 -Width 50 -Height 10
        }
        $g.PointCount | Should -Be 100
        $g.Maximum | Should -Be 100
        ($g.Points -split ' ') | Should -Contain '25.5,0'
    }

    It '表示範囲と Minimum / Maximum を指定できる' {
        $g = InModuleScope NCLogTools {
            Get-NCLogPlotGeometry -Value ([float[]](99, 0, 10, 99)) -Start 1 -End 2 -Width 10 -Height 20 -Minimum 0 -Maximum 20
        }
        $g.Points | Should -Be '0,20 10,10'
        $g.Start | Should -Be 1
        $g.End | Should -Be 2
    }

    It 'Margin で上下に余白を足す' {
        $g = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]](0, 10)) -Start 0 -End 1 -Width 10 -Height 10 -Margin 0.1 }
        $g.Minimum | Should -Be -1
        $g.Maximum | Should -Be 11
    }

    It '全点が同じ値なら中央の水平線。1点なら左右端まで' {
        $flat = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]](5, 5)) -Start 0 -End 1 -Width 10 -Height 20 }
        $flat.Points | Should -Be '0,10 10,10'
        $one = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]](3)) -Start 0 -End 0 -Width 10 -Height 20 }
        $one.Points | Should -Be '0,10 10,10'
    }

    It '範囲はデータ内に収め、空データは点なし' {
        $g = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]](1, 2, 3)) -Start -5 -End 99 -Width 10 -Height 10 }
        $g.Start | Should -Be 0
        $g.End | Should -Be 2
        $empty = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]]@()) -Start 0 -End 0 -Width 10 -Height 10 }
        $empty.PointCount | Should -Be 0
        $empty.Points | Should -Be ''
        $reversed = InModuleScope NCLogTools { Get-NCLogPlotGeometry -Value ([float[]](1, 2, 3)) -Start 2 -End 1 -Width 10 -Height 10 }
        $reversed.PointCount | Should -Be 0
    }

    It '座標はカルチャに依存せず . 区切り' {
        $g = InModuleScope NCLogTools {
            $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                Get-NCLogPlotGeometry -Value ([float[]](0, 1, 2)) -Start 0 -End 2 -Width 10 -Height 3
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
            }
        }
        $g.Points | Should -Be '0,3 5,1.5 10,0'
    }
}

Describe 'Get-NCLogByteInterpretation' {
    It '各型をリトルエンディアンで解釈する' {
        $bytes = [byte[]]::new(8)
        [System.BitConverter]::GetBytes([single]1.5).CopyTo($bytes, 0)
        $r = InModuleScope NCLogTools -Parameters @{ Bytes = $bytes } {
            param($Bytes)
            Get-NCLogByteInterpretation -Bytes $Bytes -Offset 0
        }
        ($r | Where-Object Type -Like 'Single*').Value | Should -Be '1.5'
        ($r | Where-Object Type -EQ 'Int32').Value | Should -Be ([string]0x3FC00000)
        ($r | Where-Object Type -EQ 'UInt8').Value | Should -Be '0'
        ($r | Where-Object Type -EQ 'Int32').Hex | Should -Be '0000C03F'
    }

    It 'Int8 は符号付き' {
        $r = InModuleScope NCLogTools { Get-NCLogByteInterpretation -Bytes ([byte[]](0xFF, 0x7F)) -Offset 0 }
        ($r | Where-Object Type -EQ 'Int8').Value | Should -Be '-1'
        ($r | Where-Object Type -EQ 'UInt8').Value | Should -Be '255'
        ($r | Where-Object Type -EQ 'Int16').Value | Should -Be '32767'
    }

    It 'ファイル終端を越える型は (範囲外)' {
        $r = InModuleScope NCLogTools { Get-NCLogByteInterpretation -Bytes ([byte[]](1, 2, 3)) -Offset 1 }
        ($r | Where-Object Type -EQ 'UInt16').Value | Should -Be '770'
        ($r | Where-Object Type -EQ 'Int32').Value | Should -Be '(範囲外)'
        ($r | Where-Object Type -Like 'Double*').Hex | Should -Be ''
    }
}

Describe 'ConvertFrom-NCLogNumberText' {
    It '<Text> は <Expected>' -ForEach @(
        @{ Text = '32'; Expected = 32 }
        @{ Text = ' 0x20 '; Expected = 32 }
        @{ Text = '0X1f'; Expected = 31 }
        @{ Text = '20h'; Expected = 32 }
        @{ Text = '0'; Expected = 0 }
    ) {
        InModuleScope NCLogTools -Parameters @{ Text = $Text } { param($Text) ConvertFrom-NCLogNumberText -Text $Text } |
            Should -Be $Expected
    }

    It '<Text> は FormatException' -ForEach @(
        @{ Text = '' }
        @{ Text = '-1' }
        @{ Text = '1.5' }
        @{ Text = '0x' }
        @{ Text = 'abc' }
        @{ Text = '99999999999999999999' }
    ) {
        { InModuleScope NCLogTools -Parameters @{ Text = $Text } { param($Text) ConvertFrom-NCLogNumberText -Text $Text -Name 'テスト' } } |
            Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage 'テスト には*'
    }
}

Describe 'Resolve-NCLogViewerLayout' {
    It '文字列を数値のレイアウトに変換する' {
        $layout = InModuleScope NCLogTools {
            Resolve-NCLogViewerLayout -HeaderSize '0x20' -RecordSize '16' -Value40Offset '4' -Value21Offset '8'
        }
        $layout.HeaderSize | Should -Be 32
        $layout.RecordSize | Should -Be 16
        $layout.Value40Offset | Should -Be 4
        $layout.Value21Offset | Should -Be 8
    }

    It '範囲外は ArgumentException' {
        { InModuleScope NCLogTools {
                Resolve-NCLogViewerLayout -HeaderSize '0' -RecordSize '4' -Value40Offset '0' -Value21Offset '0'
            } } | Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage 'レコードサイズ は*'
    }

    It 'オフセット + 4 byte がレコードを超えたら ArgumentException' {
        { InModuleScope NCLogTools {
                Resolve-NCLogViewerLayout -HeaderSize '0' -RecordSize '16' -Value40Offset '4' -Value21Offset '13'
            } } | Should -Throw -ExpectedMessage 'Value21Offset (13)*'
    }

    It '数値でなければ FormatException' {
        { InModuleScope NCLogTools {
                Resolve-NCLogViewerLayout -HeaderSize 'x' -RecordSize '16' -Value40Offset '4' -Value21Offset '8'
            } } | Should -Throw -ExceptionType ([System.FormatException])
    }
}
