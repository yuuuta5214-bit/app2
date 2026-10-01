#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# 「BIN を読み込むと PC が固まる」不具合の回帰テスト。全 OS で実行する。
#   - 解析・統計・グラフ計算の速さ (C# 版) と、PowerShell 版 (C# が使えない環境用) との結果の一致
#   - 解析結果は選択中のファイルだけが持ち、ほかは要約だけにする (メモリの使い過ぎ防止)
#   - 大きな配列を $( if ... ) で受け渡さない (パイプラインで1要素ずつ展開されて非常に遅くなる)

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    # 100 万レコード (約 16MB。ビューアーで開ける最大サイズ相当)。値は規則的に変える
    $script:bigCount = 1000000
    $bytes = [byte[]]::new(0x20 + $bigCount * 16 + 3)
    for ($i = 0; $i -lt $bigCount; $i += 1) {
        $o = 0x20 + $i * 16
        [System.BitConverter]::GetBytes([uint16]($i % 2001)).CopyTo($bytes, $o + 4)
        $wire = if ($i % 100000 -eq 7) { [double]::NaN } else { [double](($i % 997) * 1000 + 250) }
        [System.BitConverter]::GetBytes($wire).CopyTo($bytes, $o + 8)
    }
    $script:bigPath = Join-Path $TestDrive 'NCLog_big.BIN'
    [System.IO.File]::WriteAllBytes($bigPath, $bytes)
    $script:bigBytes = $bytes

    function Invoke-ViewData {
        param([byte[]]$Bytes, [switch]$PowerShellOnly)
        InModuleScope NCLogTools -Parameters @{ B = $Bytes; P = $bigPath; PS = [bool]$PowerShellOnly } {
            param($B, $P, $PS)
            $script:NCLogNativeDisabled = $PS
            try {
                New-NCLogViewData -Bytes $B -Path $P -HeaderSize 0x20 -RecordSize 16 -Value40Offset 4 -Value21Offset 8
            }
            finally {
                $script:NCLogNativeDisabled = $false
            }
        }
    }
}

AfterAll {
    InModuleScope NCLogTools { $script:NCLogNativeDisabled = $false }
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe '高速版 (C#) の解析処理' {
    It 'この環境では C# 版が使える' {
        InModuleScope NCLogTools { Test-NCLogNative } | Should -BeTrue
    }

    It '無効化すると PowerShell 版を使う (C# が使えない環境の代わり)' {
        InModuleScope NCLogTools {
            $script:NCLogNativeDisabled = $true
            try { Test-NCLogNative } finally { $script:NCLogNativeDisabled = $false }
        } | Should -BeFalse
    }

    It 'C# 版と PowerShell 版の解析結果が完全に一致する (NaN・端数を含む)' {
        $small = [byte[]]$bigBytes[0..(0x20 + 300000 * 16 + 2)]
        $native = Invoke-ViewData -Bytes $small
        $ps = Invoke-ViewData -Bytes $small -PowerShellOnly
        $native.RecordCount | Should -Be 300000
        $native.TrailingBytes | Should -Be 3
        $native.InvalidCount | Should -Be $ps.InvalidCount
        $native.InvalidCount | Should -Be 3
        foreach ($name in 'Value40', 'Plot40', 'Plot21') {
            [System.Linq.Enumerable]::SequenceEqual([double[]]$native.$name, [double[]]$ps.$name) | Should -BeTrue -Because $name
        }
        # NaN は SequenceEqual でも等しいとみなされる (double.Equals)
        [System.Linq.Enumerable]::SequenceEqual([double[]]$native.Value21, [double[]]$ps.Value21) | Should -BeTrue
        for ($k = 0; $k -lt 2; $k++) {
            foreach ($p in 'Count', 'Minimum', 'Maximum', 'Average', 'StdDev') {
                $native.Statistics[$k].$p | Should -Be $ps.Statistics[$k].$p -Because "Statistics[$k].$p"
            }
        }
    }

    It 'グラフの座標も C# 版と PowerShell 版で一致する' {
        $data = Invoke-ViewData -Bytes $bigBytes
        $plot = $data.Plot21
        $results = foreach ($disabled in $false, $true) {
            InModuleScope NCLogTools -Parameters @{ V = $plot; D = $disabled } {
                param($V, $D)
                $script:NCLogNativeDisabled = $D
                try {
                    (Get-NCLogPlotGeometry -Value $V -Start 1000 -End 900000 -Width 800 -Height 300 -Margin 0.05).Points
                    (Get-NCLogPlotGeometry -Value $V -Start 10 -End 600 -Width 800 -Height 300).Points
                }
                finally {
                    $script:NCLogNativeDisabled = $false
                }
            }
        }
        $results.Count | Should -Be 4
        $results[0] | Should -BeExactly $results[2]
        $results[1] | Should -BeExactly $results[3]
    }
}

Describe '大きなファイル (100 万レコード) でも固まらない' {
    It '解析と統計が数秒以内に終わる (修正前は 5 秒以上、PowerShell 版のみ)' {
        [void](InModuleScope NCLogTools { Test-NCLogNative })   # コンパイル時間は除く
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $data = Invoke-ViewData -Bytes $bigBytes
        $sw.Stop()
        $data.RecordCount | Should -Be $bigCount
        $data.InvalidCount | Should -Be 10
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3
    }

    It '全体表示のグラフ計算 (2 本) が 2 秒以内に終わる' {
        $data = Invoke-ViewData -Bytes $bigBytes
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        InModuleScope NCLogTools -Parameters @{ A = $data.Plot40; B = $data.Plot21; N = $data.RecordCount } {
            param($A, $B, $N)
            [void](Get-NCLogPlotGeometry -Value $A -Start 0 -End ($N - 1) -Width 1200 -Height 300 -Margin 0.05)
            [void](Get-NCLogPlotGeometry -Value $B -Start 0 -End ($N - 1) -Width 1200 -Height 300 -Margin 0.05)
        }
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 2
    }

    It '大きな配列を $( if ... ) で受け渡すコードがない (1要素ずつ展開されて数秒かかるため)' {
        $root = Join-Path $PSScriptRoot '..' 'NCLogTools'
        $code = (Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' | Get-Content -Raw) -join "`n"
        $pattern = '\$\(\s*if\s*\([^)]*\)\s*\{\s*\$[\w.]+\.(Plot40|Plot21|Value40|Value21|Bytes|Valid)\s*\}|\$\(\s*if\s*\([^)]*\)\s*\{\s*\$Valid\s*\}'
        @([regex]::Matches($code, $pattern) | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
    }
}

Describe 'ファイル一覧の解析結果の保持 (選択中のファイルだけ)' {
    BeforeAll {
        $script:smallPath = (New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_small.BIN') -Records @(
                @{ V40 = 2000; V21 = 1000 }
                @{ V40 = 1500; V21 = [double]::NaN }
                @{ V40 = 1800; V21 = 900.5 }
            )).FullName
        $script:layout = @{ HeaderSize = 0x20; RecordSize = 16; Value40Offset = 4; Value21Offset = 8 }
    }

    It '解放しても要約 (件数・レイアウト) は残り、出力できるかの判定に使える' {
        $f = InModuleScope NCLogTools -Parameters @{ P = $smallPath; L = $layout } {
            param($P, $L)
            $data = Read-NCLogViewerFileData -LiteralFilePath $P -Layout $L
            $file = New-NCLogViewerFile -Path $P -Data $data
            $file.ReleaseData()
            $file.LaserText = '2000'; $file.WireText = '1000'; $file.RatioText = '50'
            Update-NCLogViewerFileState -File @($file)
            $file
        }
        $f.Data | Should -BeNullOrEmpty
        $f.RecordCount | Should -Be 3
        $f.InvalidCount | Should -Be 1
        $f.Layout.Value21Offset | Should -Be 8
        $f.IsReady | Should -BeTrue
    }

    It '解放したファイルは Import-NCLogViewerFileData で読み直せる' {
        $data = InModuleScope NCLogTools -Parameters @{ P = $smallPath; L = $layout } {
            param($P, $L)
            $file = New-NCLogViewerFile -Path $P -Data (Read-NCLogViewerFileData -LiteralFilePath $P -Layout $L)
            $file.ReleaseData()
            Import-NCLogViewerFileData -File $file
        }
        $data.RecordCount | Should -Be 3
        $data.Value21[2] | Should -Be 900.5
    }

    It 'レイアウトを指定すると、読み込み済みのバイト列を解析し直して要約も更新する' {
        $r = InModuleScope NCLogTools -Parameters @{ P = $smallPath; L = $layout } {
            param($P, $L)
            $file = New-NCLogViewerFile -Path $P -Data (Read-NCLogViewerFileData -LiteralFilePath $P -Layout $L)
            $file.PickedRecord = 2
            [void](Import-NCLogViewerFileData -File $file -Layout @{ HeaderSize = 0x20; RecordSize = 32; Value40Offset = 4; Value21Offset = 8 })
            $file
        }
        $r.Layout.RecordSize | Should -Be 32
        $r.RecordCount | Should -Be 1
        # レコード数より大きい取得位置は取り消す
        $r.PickedRecord | Should -Be -1
    }

    It '読み直すときにファイルがなければ例外 (画面ではメッセージを表示して空の表示にする)' {
        $gone = (New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_gone.BIN') -Records @(@{ V40 = 1; V21 = 1 })).FullName
        {
            InModuleScope NCLogTools -Parameters @{ P = $gone; L = $layout } {
                param($P, $L)
                $file = New-NCLogViewerFile -Path $P -Data (Read-NCLogViewerFileData -LiteralFilePath $P -Layout $L)
                $file.ReleaseData()
                Remove-Item -LiteralPath $P
                Import-NCLogViewerFileData -File $file
            }
        } | Should -Throw
    }

    It '多数のファイルを開いて解放すると、メモリに解析結果が残らない' {
        $before = [System.GC]::GetTotalMemory($true)
        $files = InModuleScope NCLogTools -Parameters @{ P = $bigPath; L = $layout } {
            param($P, $L)
            foreach ($k in 1..5) {
                $file = New-NCLogViewerFile -Path $P -Data (Read-NCLogViewerFileData -LiteralFilePath $P -Layout $L)
                $file.ReleaseData()
                $file
            }
        }
        $after = [System.GC]::GetTotalMemory($true)
        @($files).Count | Should -Be 5
        @($files | Where-Object { $null -ne $_.Data }).Count | Should -Be 0
        # 解放しない場合は 1 ファイル約 60MB × 5。解放すれば増加はわずか
        ($after - $before) / 1MB | Should -BeLessThan 50
    }
}

Describe 'CSV 出力の高速版 (Write-NCLogViewCsv)' {
    BeforeAll {
        $script:layout16 = @{ HeaderSize = 0x20; RecordSize = 16; Value40Offset = 4; Value21Offset = 8 }
        # 数値の表記が揺れやすい値と、パスに " を含む場合 (Windows では使えないため Linux/macOS のみ) を確認する
        $name = if ($IsWindows) { 'NCLog_csv.BIN' } else { 'NCLog_"q".BIN' }
        $script:csvSource = (New-NCLogTestFile -Path (Join-Path $TestDrive $name) -Records @(
                @{ V40 = 2000; V21 = 1000.5 }
                @{ V40 = 0; V21 = 0 }
                @{ V40 = 65535; V21 = 1234.567 }
                @{ V40 = 1; V21 = [double]::NaN }
                @{ V40 = 12; V21 = 0.1 }
                @{ V40 = 13; V21 = 0.00001 }
                @{ V40 = 14; V21 = 123456789.123 }
                @{ V40 = 15; V21 = -42.25 }
            )).FullName
    }

    It 'Export-NCLogValue -Format CSV とバイト単位で同じ内容 (<Mode>)' -ForEach @(@{ Mode = 'C#' }, @{ Mode = 'PowerShell' }) {
        $expected = Join-Path $TestDrive "expected_$Mode.csv"
        $actual = Join-Path $TestDrive "actual_$Mode.csv"
        Export-NCLogValue -LiteralPath $csvSource -Format CSV -OutputPath $expected -Force 6>$null
        $written = InModuleScope NCLogTools -Parameters @{ S = $csvSource; O = $actual; L = $layout16; D = ($Mode -eq 'PowerShell') } {
            param($S, $O, $L, $D)
            $script:NCLogNativeDisabled = $D
            try { Write-NCLogViewCsv -SourcePath $S -OutputPath $O -Layout $L } finally { $script:NCLogNativeDisabled = $false }
        }
        $written | Should -Be 7
        [System.IO.File]::ReadAllBytes($actual) | Should -Be ([System.IO.File]::ReadAllBytes($expected))
    }

    It '既存ファイルは Force がなければ上書きせず、残す' {
        $out = Join-Path $TestDrive 'exists.csv'
        Set-Content -LiteralPath $out -Value 'keep' -NoNewline
        { InModuleScope NCLogTools -Parameters @{ S = $csvSource; O = $out; L = $layout16 } {
                param($S, $O, $L)
                Write-NCLogViewCsv -SourcePath $S -OutputPath $O -Layout $L
            } } | Should -Throw
        Get-Content -LiteralPath $out -Raw | Should -Be 'keep'
    }

    It '読み込みに失敗したら CSV を作らない' {
        $out = Join-Path $TestDrive 'never.csv'
        { InModuleScope NCLogTools -Parameters @{ S = (Join-Path $TestDrive 'missing.BIN'); O = $out; L = $layout16 } {
                param($S, $O, $L)
                Write-NCLogViewCsv -SourcePath $S -OutputPath $O -Layout $L
            } } | Should -Throw
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It '100 万レコードを 5 秒以内・少ないメモリで出力する (Export-NCLogValue は約 35 秒・2GB)' {
        $out = Join-Path $TestDrive 'big.csv'
        [System.GC]::Collect()
        $before = [System.GC]::GetTotalMemory($true)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $written = InModuleScope NCLogTools -Parameters @{ S = $bigPath; O = $out; L = $layout16 } {
            param($S, $O, $L)
            Write-NCLogViewCsv -SourcePath $S -OutputPath $O -Layout $L
        }
        $sw.Stop()
        $written | Should -Be ($bigCount - 10)
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
        # 書き終えたら解析結果は残らない
        ([System.GC]::GetTotalMemory($true) - $before) / 1MB | Should -BeLessThan 30
        # ReadLines | Select-Object -First は途中で止めるとファイルを開いたままにする (Windows では後始末で削除できない)
        $reader = [System.IO.StreamReader]::new($out)
        try {
            $lines = @($reader.ReadLine(), $reader.ReadLine())
        }
        finally {
            $reader.Dispose()
        }
        $lines[0] | Should -Be '"SourceFile","RecordNumber","Value40","Value21"'
        $lines[1] | Should -BeLike '*"0","0","0.25"'
    }

    It '一括出力は各ファイルの処理前に進捗を知らせる' {
        $outDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'progress') -Force
        $calls = InModuleScope NCLogTools -Parameters @{ S = $csvSource; D = $outDir.FullName } {
            param($S, $D)
            $log = [System.Collections.Generic.List[string]]::new()
            $items = foreach ($n in 'a', 'b') {
                [pscustomobject]@{ SourcePath = $S; OutputPath = (Join-Path $D "$n.csv"); ValidCount = 7
                    HeaderSize = 0x20; RecordSize = 16; Value40Offset = 4; Value21Offset = 8 }
            }
            $r = @(Invoke-NCLogBatchCsvExport -Item @($items) -OnProgress { param($i, $n, $it) $log.Add("$i/$n $([System.IO.Path]::GetFileName($it.OutputPath))") })
            $r.Result | Should -Be @('Exported', 'Exported')
            $r[0].Message | Should -Be '7 件'
            $log
        }
        $calls | Should -Be @('1/2 a.csv', '2/2 b.csv')
    }
}
