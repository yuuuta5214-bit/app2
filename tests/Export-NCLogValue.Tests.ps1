#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    $script:log = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_export.BIN') -Records @(
        @{ V40 = 10.5; V21 = 1000 }
        @{ V40 = 0; V21 = 0 }
        @{ V40 = 30.25; V21 = 3000 }
    )
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Export-NCLogValue' {

    Context 'パイプラインへの出力 (v1.0 では Write-Host で取得不可だった)' {
        It 'CSV を文字列として返す' {
            $csv = @(Export-NCLogValue -Path $log.FullName -Format CSV)
            $csv.Count | Should -Be 4
            $csv[0] | Should -Be '"SourceFile","RecordNumber","Value40","Value21"'
            $rows = $csv | ConvertFrom-Csv
            $rows[2].Value40 | Should -Be '30.25'
            $rows[2].Value21 | Should -Be '3000'
        }

        It 'TSV はタブ区切り' {
            $tsv = @(Export-NCLogValue -Path $log.FullName -Format TSV)
            $tsv[0] | Should -Be "`"SourceFile`"`t`"RecordNumber`"`t`"Value40`"`t`"Value21`""
        }

        It 'JSON は有効な配列 (1件でも配列)' {
            $json = Export-NCLogValue -Path $log.FullName -Format JSON -MaxRecords 1 | Out-String
            $parsed = $json | ConvertFrom-Json -NoEnumerate
            $parsed.Count | Should -Be 1
            $parsed[0].Value40 | Should -Be 10.5
            $parsed[0].PSObject.Properties.Name | Should -Be @('SourceFile', 'RecordNumber', 'Value40', 'Value21')
        }

        It 'Raw は "RecordNumber,Value40,Value21"' {
            Export-NCLogValue -Path $log.FullName -Format Raw | Should -Be @('0,10.5,1000', '1,0,0', '2,30.25,3000')
        }

        It 'Raw はカルチャに依存しない (小数点がカンマのロケールでも "." を使う)' {
            $original = [System.Globalization.CultureInfo]::CurrentCulture
            try {
                [System.Globalization.CultureInfo]::CurrentCulture = 'de-DE'
                (Export-NCLogValue -Path $log.FullName -Format Raw)[0] | Should -Be '0,10.5,1000'
            }
            finally {
                [System.Globalization.CultureInfo]::CurrentCulture = $original
            }
        }

        It 'Table は書式データを返し、文字列化すると列見出しを含む' {
            $text = Export-NCLogValue -Path $log.FullName | Out-String -Width 200
            $text | Should -Match 'RecordNumber'
            $text | Should -Match '30\.25'
        }

        It '-AsObject は NCLog.Record を返す' {
            $r = @(Export-NCLogValue -Path $log.FullName -AsObject -HideZeros)
            $r.Count | Should -Be 2
            $r[0].PSObject.TypeNames | Should -Contain 'NCLog.Record'
        }

        It 'Timestamp 列 (v1.0 のダミー値) は出力しない' {
            (Export-NCLogValue -Path $log.FullName -AsObject)[0].PSObject.Properties.Name | Should -Not -Contain 'Timestamp'
        }
    }

    Context '-Statistics' {
        It '統計はホスト (Information ストリーム) に出し、データ出力には混ぜない' {
            $out = @(Export-NCLogValue -Path $log.FullName -Format Raw -Statistics -InformationVariable info 6>$null)
            $out.Count | Should -Be 3
            $text = ($info | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
            $text | Should -Match 'ADD_40_0'
            $text | Should -Match 'ADD_21_0'
        }

        It "区切り線は '─' 60 文字 (v1.0 では '─ * 60' と表示された)" {
            $null = Export-NCLogValue -Path $log.FullName -AsObject -Statistics -InformationVariable info 6>$null
            $info.MessageData.ForEach({ $_.ToString() }) | Should -Contain ('─' * 60)
        }

        It '統計は -HideZeros 適用後のデータを対象にする' {
            $null = Export-NCLogValue -Path $log.FullName -AsObject -HideZeros -Statistics -InformationVariable info 6>$null
            $text = ($info | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
            $text | Should -Match '件数:\s+2'
        }
    }

    Context 'ファイル出力' {
        BeforeEach {
            $script:out = Join-Path $TestDrive "out_$([guid]::NewGuid()).csv"
        }

        It 'CSV を UTF-8 (BOM 付き) で保存する' {
            Export-NCLogValue -Path $log.FullName -Format CSV -OutputPath $out 6>$null
            $bytes = [System.IO.File]::ReadAllBytes($out)
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
            (Get-Content -LiteralPath $out | ConvertFrom-Csv).Count | Should -Be 3
        }

        It '-Encoding utf8NoBOM では BOM を付けない' {
            Export-NCLogValue -Path $log.FullName -Format CSV -OutputPath $out -Encoding utf8NoBOM 6>$null
            [System.IO.File]::ReadAllBytes($out)[0] | Should -Be ([byte][char]'"')
        }

        It '既存ファイルは -Force なしでは上書きしない' {
            Set-Content -LiteralPath $out -Value 'keep'
            { Export-NCLogValue -Path $log.FullName -Format CSV -OutputPath $out } |
                Should -Throw -ErrorId 'OutputFileExists,Export-NCLogValue'
            Get-Content -LiteralPath $out | Should -Be 'keep'
        }

        It '-Force なら上書きする' {
            Set-Content -LiteralPath $out -Value 'old'
            Export-NCLogValue -Path $log.FullName -Format Raw -OutputPath $out -Force 6>$null
            Get-Content -LiteralPath $out | Should -Be @('0,10.5,1000', '1,0,0', '2,30.25,3000')
        }

        It '-WhatIf ではファイルを作らない' {
            Export-NCLogValue -Path $log.FullName -Format CSV -OutputPath $out -WhatIf
            Test-Path -LiteralPath $out | Should -BeFalse
        }

        It '出力先フォルダが存在しなければエラー' {
            { Export-NCLogValue -Path $log.FullName -OutputPath (Join-Path $TestDrive 'nodir' 'x.csv') } |
                Should -Throw -ErrorId 'OutputDirectoryNotFound,Export-NCLogValue'
        }

        It '出力先がフォルダならエラー' {
            { Export-NCLogValue -Path $log.FullName -OutputPath $TestDrive -Force } |
                Should -Throw -ErrorId 'OutputPathIsDirectory,Export-NCLogValue'
        }

        It '相対パスの OutputPath は PowerShell のカレントロケーション基準' {
            Push-Location -LiteralPath $TestDrive
            try {
                Export-NCLogValue -Path $log.FullName -Format Raw -OutputPath './relative.txt' -Force 6>$null
                Test-Path -LiteralPath (Join-Path $TestDrive 'relative.txt') | Should -BeTrue
            }
            finally {
                Pop-Location
            }
        }

        It 'Table 形式のファイルは列が切り詰められない' {
            Export-NCLogValue -Path $log.FullName -Format Table -OutputPath $out 6>$null
            (Get-Content -LiteralPath $out -Raw) | Should -Match ([regex]::Escape($log.FullName))
        }
    }

    Context '入力とエラー' {
        It '複数ファイルをパイプラインで受け取り、MaxRecords を合計に適用する' {
            $second = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_export2.BIN') -Records @(
                @{ V40 = 1; V21 = 1 }
                @{ V40 = 2; V21 = 2 }
            )
            $r = @(Get-ChildItem -LiteralPath $log.FullName, $second.FullName |
                    Export-NCLogValue -AsObject -MaxRecords 4)
            $r.Count | Should -Be 4
            $r[-1].SourceFile | Should -Be $second.FullName
        }

        It 'データがなければ警告する' {
            $tiny = Join-Path $TestDrive 'empty.BIN'
            [System.IO.File]::WriteAllBytes($tiny, [byte[]]::new(0x20))
            $null = Export-NCLogValue -Path $tiny -WarningVariable warn -WarningAction SilentlyContinue
            $warn.Message | Should -Contain '処理対象のデータがありません'
        }

        It '不正なレイアウトはファイルを読む前に終了する' {
            { Export-NCLogValue -Path $log.FullName -RecordSize 8 -Value21Offset 8 } |
                Should -Throw -ErrorId 'InvalidRecordLayout,Export-NCLogValue'
        }

        It '-ErrorAction Stop は内部の読み取りエラーにも適用される' {
            { Export-NCLogValue -Path (Join-Path $TestDrive 'missing.BIN') -ErrorAction Stop } | Should -Throw
        }
    }
}
