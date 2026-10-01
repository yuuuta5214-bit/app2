#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    $nan = [double]::NaN
    $script:basic = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_basic.BIN') -Records @(
        @{ V40 = 2000; V21 = 1000.5 }
        @{ V40 = 1800; V21 = 900 }
        @{ V40 = 1500; V21 = 812.25 }
    )
    $script:withNaN = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_nan.BIN') -Records @(
        @{ V40 = 2000; V21 = 1000.5 }
        @{ V40 = 1800; V21 = $nan }
        @{ V40 = 1500; V21 = 812.25 }
        @{ V40 = 1000; V21 = 4000 }
    )
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Get-NCLogRecord' {

    Context '基本的な読み取り' {
        It '全レコードを NCLog.Record として返す' {
            $r = @(Get-NCLogRecord -Path $basic.FullName)
            $r.Count | Should -Be 3
            $r[0].PSObject.TypeNames | Should -Contain 'NCLog.Record'
        }

        It 'Value40 / Value21 / RecordNumber / SourceFile を正しく読む' {
            $r = @(Get-NCLogRecord -Path $basic.FullName)
            $r[2].Value40 | Should -Be 1500
            $r[2].Value21 | Should -Be 812.25
            $r[2].RecordNumber | Should -Be 2
            $r[2].SourceFile | Should -Be $basic.FullName
        }

        It 'Value40 は整数 (UInt16 を Int32 で返す)、Value21 は Double' {
            $r = Get-NCLogRecord -Path $basic.FullName -MaxRecords 1
            $r.Value40 | Should -BeOfType [int]
            $r.Value21 | Should -BeOfType [double]
        }

        It 'ADD_40_0 は +4 の UInt16 (2 byte)、ADD_21_0 は +8 の Double を 1000 で割った値' {
            $bytes = [byte[]]::new(0x20 + 16)
            [System.BitConverter]::GetBytes([uint16]65535).CopyTo($bytes, 0x20 + 4)
            # +6～+7 はレーザー出力に含まれない (UInt16 の範囲外の値で確認する)
            $bytes[0x20 + 6] = 0xFF
            $bytes[0x20 + 7] = 0xFF
            [System.BitConverter]::GetBytes([double]1234567).CopyTo($bytes, 0x20 + 8)
            $raw = Join-Path $TestDrive 'NCLog_raw.BIN'
            [System.IO.File]::WriteAllBytes($raw, $bytes)

            $r = Get-NCLogRecord -Path $raw
            $r.Value40 | Should -Be 65535
            $r.Value21 | Should -Be 1234.567
        }

        It '-FilePath 別名を受け付ける (v1.0 互換)' {
            @(Get-NCLogRecord -FilePath $basic.FullName).Count | Should -Be 3
        }

        It '1MB のチャンク境界をまたいでも全レコードを正しく読む' {
            # 16 byte * 65536 = 1MB。境界の前後を含むよう 65536 + 3 件作る
            $count = 65536 + 3
            $bytes = [byte[]]::new(0x20 + $count * 16)
            for ($i = 0; $i -lt $count; $i++) {
                [System.BitConverter]::GetBytes([uint16]($i % 65536)).CopyTo($bytes, 0x20 + $i * 16 + 4)
                [System.BitConverter]::GetBytes([double]($i * 2 * 1000)).CopyTo($bytes, 0x20 + $i * 16 + 8)
            }
            $big = Join-Path $TestDrive 'NCLog_big.BIN'
            [System.IO.File]::WriteAllBytes($big, $bytes)

            $r = @(Get-NCLogRecord -Path $big)
            $r.Count | Should -Be $count
            $r[65535].Value40 | Should -Be 65535
            $r[65536].Value40 | Should -Be 0
            $r[65536].Value21 | Should -Be 131072
            $r[-1].RecordNumber | Should -Be ($count - 1)
        }
    }

    Context '無効値の扱い (v1.0 の列ずれ不具合の回帰テスト)' {
        It 'ADD_21_0 が NaN のレコードはレコードごと除外され、対応がずれない' {
            $r = @(Get-NCLogRecord -Path $withNaN.FullName)
            $r.Count | Should -Be 3
            $r.RecordNumber | Should -Be @(0, 2, 3)
            $r[1].Value40 | Should -Be 1500
            $r[1].Value21 | Should -Be 812.25
            $r[2].Value40 | Should -Be 1000
            $r[2].Value21 | Should -Be 4000
        }

        It '<Name> を含むレコードを除外する' -ForEach @(
            @{ Name = 'ADD_21_0 = NaN'; V40 = 1; V21 = [double]::NaN }
            @{ Name = 'ADD_21_0 = +Infinity'; V40 = 1; V21 = [double]::PositiveInfinity }
            @{ Name = 'ADD_21_0 = -Infinity'; V40 = 1; V21 = [double]::NegativeInfinity }
        ) {
            $f = New-NCLogTestFile -Path (Join-Path $TestDrive "inv_$([guid]::NewGuid()).BIN") -Records @(
                @{ V40 = 5; V21 = 50 }
                @{ V40 = $V40; V21 = $V21 }
                @{ V40 = 6; V21 = 60 }
            )
            $r = @(Get-NCLogRecord -LiteralPath $f.FullName)
            $r.RecordNumber | Should -Be @(0, 2)
            $r.Value21 | Should -Be @(50, 60)
        }
    }

    Context '-HideZeros' {
        BeforeAll {
            $script:zeros = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_zero.BIN') -Records @(
                @{ V40 = 0; V21 = 0 }
                @{ V40 = 0; V21 = 100 }
                @{ V40 = 5; V21 = 0 }
                @{ V40 = 0; V21 = 0 }
            )
        }

        It '指定なしでは 0 のレコードも返す' {
            @(Get-NCLogRecord -Path $zeros.FullName).Count | Should -Be 4
        }

        It '両方 0 のレコードだけを除外する' {
            $r = @(Get-NCLogRecord -Path $zeros.FullName -HideZeros)
            $r.RecordNumber | Should -Be @(1, 2)
        }
    }

    Context '-MaxRecords' {
        It '1ファイル内で上限件数に達したら止める' {
            @(Get-NCLogRecord -Path $basic.FullName -MaxRecords 2).Count | Should -Be 2
        }

        It '複数ファイルの合計に対して上限を適用する' {
            $r = @(Get-NCLogRecord -Path $basic.FullName, $withNaN.FullName -MaxRecords 4)
            $r.Count | Should -Be 4
            ($r | Where-Object SourceFile -EQ $withNaN.FullName).Count | Should -Be 1
        }

        It '0 以下は拒否する (v1.0 では 0 でも1件出力された)' {
            { Get-NCLogRecord -Path $basic.FullName -MaxRecords 0 } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Get-NCLogRecord'
        }
    }

    Context 'パス解決' {
        It 'ワイルドカードを展開する (v1.0 では失敗した)' {
            $r = @(Get-NCLogRecord -Path (Join-Path $TestDrive 'NCLog_*.BIN') -ErrorAction Stop)
            ($r.SourceFile | Sort-Object -Unique) | Should -Contain $basic.FullName
            ($r.SourceFile | Sort-Object -Unique) | Should -Contain $withNaN.FullName
        }

        It '相対パスを PowerShell のカレントロケーション基準で解決する (v1.0 では失敗した)' {
            $sub = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'sub') -Force
            Push-Location -LiteralPath $sub.FullName
            try {
                $r = @(Get-NCLogRecord -Path '../NCLog_basic.BIN' -ErrorAction Stop)
                $r.Count | Should -Be 3
                $r[0].SourceFile | Should -Be $basic.FullName
            }
            finally {
                Pop-Location
            }
        }

        It 'Get-ChildItem の出力をパイプラインで受け取る' {
            $r = @(Get-ChildItem -LiteralPath $basic.FullName | Get-NCLogRecord)
            $r.Count | Should -Be 3
        }

        It "-LiteralPath は '[' を含むファイル名を扱える" {
            $f = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog[1].BIN') -Records @(@{ V40 = 1; V21 = 2 })
            @(Get-NCLogRecord -LiteralPath $f.FullName -ErrorAction Stop).Count | Should -Be 1
        }

        It '存在しないファイルは PathNotFound の非終了エラーにし、残りは処理を続ける' {
            $missing = Join-Path $TestDrive 'nope.BIN'
            $r = @(Get-NCLogRecord -Path $missing, $basic.FullName -ErrorVariable err -ErrorAction SilentlyContinue)
            $r.Count | Should -Be 3
            $err.Count | Should -Be 1
            $err[0].FullyQualifiedErrorId | Should -Be 'PathNotFound,Get-NCLogRecord'
        }

        It '一致しないワイルドカードはエラーにする' {
            { Get-NCLogRecord -Path (Join-Path $TestDrive 'nomatch_*.BIN') -ErrorAction Stop } |
                Should -Throw -ErrorId 'PathNotFound,Get-NCLogRecord'
        }

        It '存在しないドライブは PathNotFound エラーにする' {
            { Get-NCLogRecord -Path 'NoSuchDrive:\x.BIN' -ErrorAction Stop } |
                Should -Throw -ErrorId 'PathNotFound,Get-NCLogRecord'
        }

        It 'ディレクトリは FileNotFound エラーにする' {
            { Get-NCLogRecord -LiteralPath $TestDrive -ErrorAction Stop } |
                Should -Throw -ErrorId 'FileNotFound,Get-NCLogRecord'
        }

        It 'ファイルシステム以外のパスは NotFileSystemPath エラーにする' {
            { Get-NCLogRecord -Path 'Env:\PATH' -ErrorAction Stop } |
                Should -Throw -ErrorId 'NotFileSystemPath,Get-NCLogRecord'
        }

        It '-ErrorAction Stop を尊重する (v1.0 では Continue で上書きされた)' {
            { Get-NCLogRecord -Path (Join-Path $TestDrive 'nope.BIN') -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'ファイル構造の異常' {
        It 'レコードが1件もないファイルは警告を出して何も返さない' {
            $tiny = Join-Path $TestDrive 'tiny.BIN'
            [System.IO.File]::WriteAllBytes($tiny, [byte[]]::new(10))
            $r = @(Get-NCLogRecord -Path $tiny -WarningVariable warn -WarningAction SilentlyContinue)
            $r.Count | Should -Be 0
            $warn[0] | Should -BeLike '*レコードが1件もありません*'
        }

        It '末尾の端数バイトは警告して無視する' {
            $f = New-NCLogTestFile -Path (Join-Path $TestDrive 'trail.BIN') -TrailingBytes 5 -Records @(
                @{ V40 = 1; V21 = 2 }
            )
            $r = @(Get-NCLogRecord -Path $f.FullName -WarningVariable warn -WarningAction SilentlyContinue)
            $r.Count | Should -Be 1
            $warn[0] | Should -BeLike '*末尾の 5 byte*'
        }
    }

    Context 'レイアウト指定' {
        It 'HeaderSize / RecordSize / オフセットを変更して読める' {
            $f = New-NCLogTestFile -Path (Join-Path $TestDrive 'layout.BIN') -HeaderSize 64 -RecordSize 32 `
                -Value40Offset 12 -Value21Offset 24 -Records @(
                @{ V40 = 11; V21 = 22 }
                @{ V40 = 33; V21 = 44 }
            )
            $r = @(Get-NCLogRecord -Path $f.FullName -HeaderSize 64 -RecordSize 32 -Value40Offset 12 -Value21Offset 24)
            $r.Value40 | Should -Be @(11, 33)
            $r.Value21 | Should -Be @(22, 44)
        }

        It 'オフセットがレコードからはみ出す場合は InvalidRecordLayout で終了する: <Name>' -ForEach @(
            @{ Name = 'ADD_21_0 (8 byte) が +9～+16'; P = @{ Value21Offset = 9 } }
            @{ Name = 'ADD_40_0 (2 byte) が +15～+16'; P = @{ Value40Offset = 15 } }
        ) {
            { Get-NCLogRecord -Path $basic.FullName @P } |
                Should -Throw -ErrorId 'InvalidRecordLayout,Get-NCLogRecord'
        }

        It 'ADD_40_0 と ADD_21_0 の位置が重なる場合は InvalidRecordLayout で終了する' {
            { Get-NCLogRecord -Path $basic.FullName -Value40Offset 8 -Value21Offset 8 } |
                Should -Throw -ErrorId 'InvalidRecordLayout,Get-NCLogRecord' -ExpectedMessage '*重なっています*'
            { Get-NCLogRecord -Path $basic.FullName -Value40Offset 14 -Value21Offset 8 } |
                Should -Throw -ErrorId 'InvalidRecordLayout,Get-NCLogRecord'
        }

        It '2つの値が隣り合う (重ならない) レイアウトは読める' {
            $f = New-NCLogTestFile -Path (Join-Path $TestDrive 'adjacent.BIN') -RecordSize 16 `
                -Value40Offset 6 -Value21Offset 8 -Records @(@{ V40 = 7; V21 = 8.5 })
            $r = Get-NCLogRecord -Path $f.FullName -Value40Offset 6 -Value21Offset 8
            $r.Value40 | Should -Be 7
            $r.Value21 | Should -Be 8.5
        }
    }

    Context 'ファイルハンドル' {
        It '他プロセスが書き込み用に開いているファイルも読める (FileShare.ReadWrite)' {
            $writer = [System.IO.FileStream]::new($basic.FullName, 'Open', 'ReadWrite', 'ReadWrite')
            try {
                @(Get-NCLogRecord -Path $basic.FullName).Count | Should -Be 3
            }
            finally {
                $writer.Dispose()
            }
        }

        It 'Select-Object -First で途中終了してもファイルを閉じる' {
            $copy = Join-Path $TestDrive 'handle.BIN'
            Copy-Item -LiteralPath $basic.FullName -Destination $copy
            $first = Get-NCLogRecord -Path $copy | Select-Object -First 1
            $first.RecordNumber | Should -Be 0
            # ハンドルが残っていれば排他オープンに失敗する
            $exclusive = [System.IO.FileStream]::new($copy, 'Open', 'ReadWrite', 'None')
            $exclusive.Dispose()
            Remove-Item -LiteralPath $copy
            Test-Path -LiteralPath $copy | Should -BeFalse
        }
    }
}
