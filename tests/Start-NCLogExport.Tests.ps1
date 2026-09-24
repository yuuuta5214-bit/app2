#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:launcher = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'tools' 'Start-NCLogExport.ps1'))
    $script:pwshPath = (Get-Process -Id $PID).Path

    function Invoke-Launcher {
        # 別プロセス・非対話モードで起動し、終了コードと出力を返す
        param([string[]]$Arguments)
        $output = & $pwshPath -NoLogo -NoProfile -NonInteractive -File $launcher @Arguments -NoPause 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
}

Describe 'Start-NCLogExport.ps1 (NCLogExport.cmd のランチャー)' {

    BeforeEach {
        $script:dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid())) -Force
        $script:log = New-NCLogTestFile -Path (Join-Path $dir 'NCLog_a.BIN') -Records @(
            @{ V40 = 10.5; V21 = 1000 }
            @{ V40 = 20; V21 = 2000 }
        )
    }

    It 'ファイルを受け取り、同じフォルダに 同名.csv を作る' {
        $r = Invoke-Launcher -Arguments $log.FullName
        $r.ExitCode | Should -Be 0
        $csv = Join-Path $dir 'NCLog_a.csv'
        (Get-Content -LiteralPath $csv | ConvertFrom-Csv).Value21 | Should -Be @('1000', '2000')
        $r.Output | Should -Match 'ADD_40_0'          # 統計を表示している
    }

    It 'フォルダを受け取ると直下の .BIN をすべて変換する' {
        $null = New-NCLogTestFile -Path (Join-Path $dir 'NCLog_b.BIN') -Records @(@{ V40 = 1; V21 = 2 })
        $r = Invoke-Launcher -Arguments $dir.FullName
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $dir 'NCLog_a.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'NCLog_b.csv') | Should -BeTrue
    }

    It 'スペースを含むパスも扱える (ドラッグ＆ドロップ想定)' {
        $spaced = New-Item -ItemType Directory -Path (Join-Path $dir 'log folder') -Force
        $f = New-NCLogTestFile -Path (Join-Path $spaced 'NCLog 1.BIN') -Records @(@{ V40 = 1; V21 = 2 })
        (Invoke-Launcher -Arguments $f.FullName).ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $spaced 'NCLog 1.csv') | Should -BeTrue
    }

    It '非対話モードでは既存 CSV を上書きせずスキップする' {
        $csv = Join-Path $dir 'NCLog_a.csv'
        Set-Content -LiteralPath $csv -Value 'keep'
        $r = Invoke-Launcher -Arguments $log.FullName
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'スキップ'
        Get-Content -LiteralPath $csv | Should -Be 'keep'
    }

    It '-Force なら既存 CSV を上書きする' {
        $csv = Join-Path $dir 'NCLog_a.csv'
        Set-Content -LiteralPath $csv -Value 'old'
        (Invoke-Launcher -Arguments $log.FullName, '-Force').ExitCode | Should -Be 0
        (Get-Content -LiteralPath $csv)[0] | Should -Be '"SourceFile","RecordNumber","Value40","Value21"'
    }

    It '存在しないパスだけなら終了コード 2' {
        (Invoke-Launcher -Arguments (Join-Path $dir 'nope.BIN')).ExitCode | Should -Be 2
    }

    It '読めないファイルがあれば終了コード 1 (他のファイルは変換する)' {
        $bad = Join-Path $dir 'NCLog_empty.BIN'
        [System.IO.File]::WriteAllBytes($bad, [byte[]]::new(4))
        $r = Invoke-Launcher -Arguments $log.FullName, $bad
        $r.ExitCode | Should -Be 1
        Test-Path -LiteralPath (Join-Path $dir 'NCLog_a.csv') | Should -BeTrue
    }
}

Describe 'NCLogExport.cmd' {
    BeforeAll {
        $script:cmdPath = Join-Path $PSScriptRoot '..' 'NCLogExport.cmd'
        $script:bytes = [System.IO.File]::ReadAllBytes($cmdPath)
    }

    It 'ASCII のみで書かれている (cmd.exe は OEM コードページで読むため)' {
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
    }

    It 'CRLF 改行である (LF のみだとラベルジャンプが誤動作する)' {
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0
    }

    It '参照先のスクリプトが存在する' {
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Match 'tools\\Start-NCLogExport\.ps1'
        $text | Should -Match 'Export-NCLogValues\.ps1'
        Test-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'tools' 'Start-NCLogExport.ps1') | Should -BeTrue
    }

    It 'パッケージの必須ファイル (モジュールを含む) を事前に確認する' {
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Match 'call :require "%~dp0NCLogTools\\NCLogTools\.psd1"'
        $text | Should -Match '(?m)^:require\r?$'
    }

    It '実行ポリシーの変更はプロセス単位のみ (-ExecutionPolicy 引数) で、恒久的な設定変更をしない' {
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Not -Match 'Set-ExecutionPolicy'
        $text | Should -Not -Match '(?i)reg(\.exe)?\s+add'
    }
}
