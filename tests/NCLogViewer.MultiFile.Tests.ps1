#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# 複数ファイル・出力ファイル名・一括 CSV 出力の画面に依存しない処理 (Private) のテスト。全 OS で実行する。

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    $script:dirA = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'A') -Force
    $script:dirB = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'B') -Force
    $script:logA1 = New-NCLogTestFile -Path (Join-Path $dirA 'NCLog_01.BIN') -Records @(@{ V40 = 2000; V21 = 1000 }, @{ V40 = 0; V21 = 0 })
    $script:logA2 = New-NCLogTestFile -Path (Join-Path $dirA 'NCLog_02.bin') -Records @(@{ V40 = 1500; V21 = 800 })
    $null = Set-Content -LiteralPath (Join-Path $dirA 'readme.txt') -Value 'x'
    $script:logB1 = New-NCLogTestFile -Path (Join-Path $dirB 'NCLog_03.BIN') -Records @(@{ V40 = 1; V21 = 2 })
    $script:invalidLog = New-NCLogTestFile -Path (Join-Path $dirB 'NCLog_nan.BIN') -Records @(@{ V40 = [single]::NaN; V21 = 1 })

    function New-TestViewerFile {
        param([string]$Path, [string]$Laser = '', [string]$Wire = '', [string]$Ratio = '')
        InModuleScope NCLogTools -Parameters @{ P = $Path; L = $Laser; W = $Wire; R = $Ratio } {
            param($P, $L, $W, $R)
            $bytes = [System.IO.File]::ReadAllBytes($P)
            $data = New-NCLogViewData -Bytes $bytes -Path $P -HeaderSize 0x20 -RecordSize 16 -Value40Offset 4 -Value21Offset 8
            $f = New-NCLogViewerFile -Path $P -Data $data
            $f.LaserText = $L; $f.WireText = $W; $f.RatioText = $R
            $f
        }
    }

    function Update-TestState {
        param([object[]]$File, [string]$OutputDirectory)
        InModuleScope NCLogTools -Parameters @{ F = $File; D = $OutputDirectory } {
            param($F, $D)
            Update-NCLogViewerFileState -File $F -OutputDirectory $D
        }
    }
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-NCLogDecimalText' {
    It '<Text> → <Expected>' -ForEach @(
        @{ Text = '50'; Expected = 50.0 }
        @{ Text = ' 12.5 '; Expected = 12.5 }
        @{ Text = '.5'; Expected = 0.5 }
        @{ Text = '５０．５'; Expected = 50.5 }
        @{ Text = '50%'; Expected = 50.0 }
        @{ Text = '50 ％'; Expected = 50.0 }
        @{ Text = '+7'; Expected = 7.0 }
    ) {
        InModuleScope NCLogTools -Parameters @{ T = $Text } {
            param($T)
            ConvertFrom-NCLogDecimalText -Text $T -Unit '%'
        } | Should -Be $Expected
    }

    It '空欄・空白・$null は $null' -ForEach @(@{ T = '' }, @{ T = '   ' }, @{ T = $null }) {
        InModuleScope NCLogTools -Parameters @{ T = $T } {
            param($T)
            ConvertFrom-NCLogDecimalText -Text $T
        } | Should -BeNullOrEmpty
    }

    It '数値でない文字列は FormatException: <T>' -ForEach @(@{ T = 'abc' }, @{ T = '1,000' }, @{ T = '1e3' }, @{ T = '1.2.3' }, @{ T = '12..' }) {
        { InModuleScope NCLogTools -Parameters @{ T = $T } {
                param($T)
                ConvertFrom-NCLogDecimalText -Text $T -Name '割合'
            } } | Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage '*割合*'
    }

    It '負の値は AllowNegative がなければエラー、あれば受け付ける' {
        { InModuleScope NCLogTools { ConvertFrom-NCLogDecimalText -Text '-1' } } |
            Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage '*0 以上*'
        InModuleScope NCLogTools { ConvertFrom-NCLogDecimalText -Text '-1.5' -AllowNegative } | Should -Be -1.5
    }

    It '単位は大文字小文字を区別せず末尾だけ取り除く' {
        InModuleScope NCLogTools { ConvertFrom-NCLogDecimalText -Text '1000 MM/MIN' -Unit 'mm/min' } | Should -Be 1000
    }
}

Describe 'Format-NCLogFileNameValue / Get-NCLogCsvFileName' {
    It '<Value> → <Expected>' -ForEach @(
        @{ Value = 2000.0; Expected = '2000' }
        @{ Value = 12.5; Expected = '12.5' }
        @{ Value = 45.678; Expected = '45.68' }
        @{ Value = 0.005; Expected = '0.01' }
        @{ Value = -0.001; Expected = '0' }
        @{ Value = -3.25; Expected = '-3.25' }
    ) {
        InModuleScope NCLogTools -Parameters @{ V = $Value } {
            param($V)
            Format-NCLogFileNameValue -Value $V
        } | Should -BeExactly $Expected
    }

    It 'カルチャに関係なく小数点は "."' {
        $saved = [System.Globalization.CultureInfo]::CurrentCulture
        try {
            [System.Globalization.CultureInfo]::CurrentCulture = 'de-DE'
            InModuleScope NCLogTools { Format-NCLogFileNameValue -Value 12.5 } | Should -BeExactly '12.5'
        }
        finally {
            [System.Globalization.CultureInfo]::CurrentCulture = $saved
        }
    }

    It 'NaN はエラー' {
        { InModuleScope NCLogTools { Format-NCLogFileNameValue -Value ([double]::NaN) } } | Should -Throw
    }

    It '「レーザー出力W_ワイヤ速度mm-min_割合%.csv」の形式' {
        InModuleScope NCLogTools { Get-NCLogCsvFileName -LaserPower 2000 -WireFeed 1000 -Ratio 50 } |
            Should -BeExactly '2000W_1000mm-min_50%.csv'
        InModuleScope NCLogTools { Get-NCLogCsvFileName -LaserPower 1999.996 -WireFeed 812.345 -Ratio 12.5 } |
            Should -BeExactly '2000W_812.35mm-min_12.5%.csv'
    }
}

Describe 'Update-NCLogViewerFileState' {
    It '3つとも入力済みなら出力名と BIN と同じフォルダの出力先を作る' {
        $f = New-TestViewerFile -Path $logA1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        Update-TestState -File @($f)
        $f.IsReady | Should -BeTrue
        $f.OutputName | Should -BeExactly '2000W_1000mm-min_50%.csv'
        $f.OutputPath | Should -Be (Join-Path $dirA.FullName '2000W_1000mm-min_50%.csv')
        $f.Status | Should -Be '出力できます'
    }

    It '出力先フォルダを指定するとそこに出力する' {
        $f = New-TestViewerFile -Path $logA1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        Update-TestState -File @($f) -OutputDirectory $dirB.FullName
        $f.OutputPath | Should -Be (Join-Path $dirB.FullName '2000W_1000mm-min_50%.csv')
    }

    It '未入力の項目を状態に表示し、出力対象にしない' {
        $f = New-TestViewerFile -Path $logA1.FullName -Laser '2000'
        Update-TestState -File @($f)
        $f.IsReady | Should -BeFalse
        $f.OutputName | Should -BeNullOrEmpty
        $f.Status | Should -Be '未入力: ワイヤ速度 / 割合'
    }

    It '数値でない入力はそのメッセージを状態に表示する' {
        $f = New-TestViewerFile -Path $logA1.FullName -Laser '2000' -Wire '1000' -Ratio 'abc'
        Update-TestState -File @($f)
        $f.IsReady | Should -BeFalse
        $f.Status | Should -BeLike '割合*数値*'
    }

    It '有効なレコードがないファイルは出力対象にしない' {
        $f = New-TestViewerFile -Path $invalidLog.FullName -Laser '1' -Wire '1' -Ratio '1'
        Update-TestState -File @($f)
        $f.IsReady | Should -BeFalse
        $f.Status | Should -Be '有効なレコードがありません'
    }

    It '出力先が重複するファイルはすべて出力不可にし、値を変えると解消する' {
        $f1 = New-TestViewerFile -Path $logA1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        $f2 = New-TestViewerFile -Path $logA2.FullName -Laser '2000.001' -Wire '1000' -Ratio '50'
        $f3 = New-TestViewerFile -Path $logB1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        Update-TestState -File @($f1, $f2, $f3)
        $f1.IsReady | Should -BeFalse
        $f2.IsReady | Should -BeFalse
        $f1.Status | Should -BeLike '*重複*2 件*'
        # 別フォルダの同名は重複ではない
        $f3.IsReady | Should -BeTrue

        $f2.RatioText = '60'
        Update-TestState -File @($f1, $f2, $f3)
        $f1.IsReady | Should -BeTrue
        $f2.IsReady | Should -BeTrue
        $f2.OutputName | Should -BeExactly '2000W_1000mm-min_60%.csv'
    }

    It '同じ出力先フォルダを指定すると別フォルダの同名も重複になる' {
        $f1 = New-TestViewerFile -Path $logA1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        $f3 = New-TestViewerFile -Path $logB1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        Update-TestState -File @($f1, $f3) -OutputDirectory $dirB.FullName
        $f1.IsReady | Should -BeFalse
        $f3.IsReady | Should -BeFalse
    }

    It '出力先フォルダが相対パスなら例外にせず状態に表示する' {
        $f = New-TestViewerFile -Path $logA1.FullName -Laser '2000' -Wire '1000' -Ratio '50'
        { Update-TestState -File @($f) -OutputDirectory 'out' } | Should -Not -Throw
        $f.IsReady | Should -BeFalse
        $f.OutputName | Should -BeExactly '2000W_1000mm-min_50%.csv'
        $f.Status | Should -BeLike '*絶対パス*'
    }

    It '空の一覧でもエラーにならない' {
        { Update-TestState -File @() } | Should -Not -Throw
    }
}

Describe 'Invoke-NCLogBatchCsvExport' {
    BeforeAll {
        function New-TestItem {
            param([string]$Source, [string]$Output, [int]$ValidCount = 1)
            [pscustomobject]@{
                SourcePath = $Source; OutputPath = $Output; ValidCount = $ValidCount
                HeaderSize = 0x20; RecordSize = 16; Value40Offset = 4; Value21Offset = 8
            }
        }
        function Invoke-TestExport {
            param([object[]]$Item, [string]$ExistingAction = 'Skip')
            InModuleScope NCLogTools -Parameters @{ I = $Item; A = $ExistingAction } {
                param($I, $A)
                Invoke-NCLogBatchCsvExport -Item $I -ExistingAction $A
            }
        }
    }

    It 'ファイルごとに指定の名前で CSV を出力する' {
        $out = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'out1') -Force
        $o1 = Join-Path $out '2000W_1000mm-min_50%.csv'
        $o2 = Join-Path $out '1500W_800mm-min_30%.csv'
        $results = @(Invoke-TestExport -Item @(
                (New-TestItem -Source $logA1.FullName -Output $o1 -ValidCount 2)
                (New-TestItem -Source $logA2.FullName -Output $o2)
            ))
        $results.Result | Should -Be @('Exported', 'Exported')
        $rows = @(Import-Csv -LiteralPath $o1)
        $rows.Count | Should -Be 2
        [double]$rows[0].Value40 | Should -Be 2000
        [double]$rows[0].Value21 | Should -Be 1000
        [double](@(Import-Csv -LiteralPath $o2)[0].Value40) | Should -Be 1500
    }

    It '既存ファイルは Skip で残し、Overwrite で上書きする' {
        $out = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'out2') -Force
        $o = Join-Path $out 'x.csv'
        Set-Content -LiteralPath $o -Value 'old'
        (Invoke-TestExport -Item @(New-TestItem -Source $logA2.FullName -Output $o)).Result | Should -Be 'Skipped'
        Get-Content -LiteralPath $o | Should -Be 'old'

        (Invoke-TestExport -Item @(New-TestItem -Source $logA2.FullName -Output $o) -ExistingAction Overwrite).Result |
            Should -Be 'Exported'
        [double](@(Import-Csv -LiteralPath $o)[0].Value40) | Should -Be 1500
    }

    It '失敗したファイルがあっても残りは出力し、理由を返す' {
        $out = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'out3') -Force
        $results = @(Invoke-TestExport -Item @(
                (New-TestItem -Source (Join-Path $TestDrive 'missing.BIN') -Output (Join-Path $out 'a.csv'))
                (New-TestItem -Source $logA2.FullName -Output (Join-Path $TestDrive 'nofolder' 'b.csv'))
                (New-TestItem -Source $logA2.FullName -Output (Join-Path $out 'c.csv') -ValidCount 0)
                (New-TestItem -Source $logA2.FullName -Output 'relative.csv')
                (New-TestItem -Source $logA2.FullName -Output (Join-Path $out 'ok.csv'))
            ))
        $results.Result | Should -Be @('Failed', 'Failed', 'Failed', 'Failed', 'Exported')
        $results[1].Message | Should -BeLike '*フォルダが存在しません*'
        $results[2].Message | Should -BeLike '*有効なレコード*'
        $results[3].Message | Should -BeLike '*パスが不正*'
        Test-Path (Join-Path $out 'a.csv') | Should -BeFalse
        Test-Path (Join-Path $out 'ok.csv') | Should -BeTrue
    }

    It '-WhatIf では出力しない' {
        $out = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'out4') -Force
        $o = Join-Path $out 'w.csv'
        $r = InModuleScope NCLogTools -Parameters @{ I = (New-TestItem -Source $logA2.FullName -Output $o) } {
            param($I)
            Invoke-NCLogBatchCsvExport -Item @($I) -WhatIf
        }
        $r.Result | Should -Be 'Skipped'
        Test-Path $o | Should -BeFalse
    }
}

Describe 'Resolve-NCLogViewerOpenTarget' {
    BeforeAll {
        function Resolve-Test {
            param([string[]]$Path, [string[]]$Existing = @(), [int]$MaxCount = 100)
            InModuleScope NCLogTools -Parameters @{ P = $Path; E = $Existing; M = $MaxCount } {
                param($P, $E, $M)
                Resolve-NCLogViewerOpenTarget -Path $P -Existing $E -MaxCount $M
            }
        }
    }

    It '複数ファイルとフォルダ (直下の .BIN を名前順、拡張子の大文字小文字は問わない) を展開する' {
        $r = Resolve-Test -Path @($logB1.FullName, $dirA.FullName)
        $r.Files | Should -Be @($logB1.FullName, $logA1.FullName, $logA2.FullName)
        $r.Messages | Should -BeNullOrEmpty
    }

    It '重複は1つにまとめ、既に開いているファイルは AlreadyOpen に分ける' {
        $r = Resolve-Test -Path @($logA1.FullName, $logA1.FullName.ToUpperInvariant(), $logA2.FullName) -Existing @($logA2.FullName)
        $r.Files | Should -Be @($logA1.FullName)
        $r.AlreadyOpen | Should -Be @($logA2.FullName)
    }

    It '存在しないパス・.BIN のないフォルダは理由を返す' {
        $empty = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty') -Force
        $r = Resolve-Test -Path @((Join-Path $TestDrive 'nope.BIN'), $empty.FullName, '', $logA1.FullName)
        $r.Files | Should -Be @($logA1.FullName)
        $r.Messages.Count | Should -Be 2
        $r.Messages[0] | Should -BeLike '*見つかりません*'
        $r.Messages[1] | Should -BeLike '*.BIN ファイルがありません*'
    }

    It '上限を超えた分は開かず、件数を知らせる' {
        $r = Resolve-Test -Path @($dirA.FullName, $logB1.FullName) -MaxCount 2
        $r.Files.Count | Should -Be 2
        $r.Messages | Should -BeLike '*2 ファイルまで*1 ファイルは開きませんでした*'
    }

    It '相対パスは絶対パスにする' {
        # プロセスのカレントディレクトリは必ず戻す (Windows では使用中のフォルダを TestDrive の後始末で削除できない)
        $savedCwd = [System.Environment]::CurrentDirectory
        Push-Location -LiteralPath $dirA.FullName
        try {
            [System.Environment]::CurrentDirectory = $dirA.FullName
            (Resolve-Test -Path @('NCLog_01.BIN')).Files | Should -Be @($logA1.FullName)
        }
        finally {
            [System.Environment]::CurrentDirectory = $savedCwd
            Pop-Location
        }
    }
}

Describe 'Get-NCLogChartIndex / Get-NCLogChartX' {
    It 'X 座標 ⇔ レコード番号 (表示範囲 100～200、幅 500)' {
        InModuleScope NCLogTools {
            Get-NCLogChartIndex -X 0 -Width 500 -Start 100 -End 200 -RecordCount 1000 | Should -Be 100
            Get-NCLogChartIndex -X 250 -Width 500 -Start 100 -End 200 -RecordCount 1000 | Should -Be 150
            Get-NCLogChartIndex -X 999 -Width 500 -Start 100 -End 200 -RecordCount 1000 | Should -Be 200
            Get-NCLogChartIndex -X -5 -Width 500 -Start 100 -End 200 -RecordCount 1000 | Should -Be 100
            Get-NCLogChartX -Index 150 -Width 500 -Start 100 -End 200 | Should -Be 250
            Get-NCLogChartX -Index 99 -Width 500 -Start 100 -End 200 | Should -BeNullOrEmpty
            Get-NCLogChartX -Index 201 -Width 500 -Start 100 -End 200 | Should -BeNullOrEmpty
            Get-NCLogChartX -Index 0 -Width 500 -Start 0 -End 0 | Should -Be 250
        }
    }

    It 'レコード数を超えない' {
        InModuleScope NCLogTools { Get-NCLogChartIndex -X 500 -Width 500 -Start 0 -End 10 -RecordCount 5 } | Should -Be 4
    }
}
