#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:builder = Join-Path $PSScriptRoot '..' 'build' 'New-NCLogToolsPackage.ps1'
    $script:zip = & $builder -DestinationPath (Join-Path $TestDrive 'dist')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
    $script:names = @($archive.Entries.FullName)
    $script:prefix = ($names[0] -split '/')[0]

    function Get-EntryBytes([string]$Name) {
        $e = $archive.GetEntry("$prefix/$Name")
        $s = $e.Open()
        try { $ms = [System.IO.MemoryStream]::new(); $s.CopyTo($ms); , $ms.ToArray() } finally { $s.Dispose() }
    }
}

AfterAll {
    if ($archive) { $archive.Dispose() }
}

Describe '配布用 ZIP' {
    It 'ルートフォルダは NCLogTools-バージョン番号' {
        $prefix | Should -Match '^NCLogTools-\d+\.\d+\.\d+$'
        $names | ForEach-Object { $_ | Should -BeLike "$prefix/*" }
    }

    It 'NCLogExport.cmd の実行に必要なファイルがすべて入っている' -ForEach @(
        @{ Name = 'NCLogExport.cmd' }
        @{ Name = 'Export-NCLogValues.ps1' }
        @{ Name = 'tools/Start-NCLogExport.ps1' }
        @{ Name = 'NCLogTools/NCLogTools.psd1' }
        @{ Name = 'NCLogTools/NCLogTools.psm1' }
        @{ Name = 'NCLogTools/NCLogTools.Format.ps1xml' }
        @{ Name = 'NCLogTools/Public/Export-NCLogValue.ps1' }
        @{ Name = 'NCLogTools/Private/Resolve-NCLogPath.ps1' }
        @{ Name = 'README.md' }
    ) {
        $names | Should -Contain "$prefix/$Name"
    }

    It 'テストやビルド用ファイルは含めない' {
        $names | Where-Object { $_ -match '/(tests|build|\.github)/' } | Should -BeNullOrEmpty
    }

    It 'パス区切りは / (Windows の展開で正しいフォルダ構造になる)' {
        $names | Where-Object { $_ -match '\\' } | Should -BeNullOrEmpty
    }

    It '<Name> は CRLF 改行' -ForEach @(
        @{ Name = 'NCLogExport.cmd' }
        @{ Name = 'Export-NCLogValues.ps1' }
        @{ Name = 'tools/Start-NCLogExport.ps1' }
    ) {
        $text = [System.Text.Encoding]::UTF8.GetString((Get-EntryBytes $Name))
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0
    }

    It 'PowerShell ファイルの UTF-8 BOM を保持している' {
        $bytes = Get-EntryBytes 'tools/Start-NCLogExport.ps1'
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'ZIP を展開したフォルダでランチャーが動く' {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        $out = Join-Path $TestDrive 'extracted'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $out)
        $launcher = Join-Path $out $prefix 'tools' 'Start-NCLogExport.ps1'
        $log = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_pkg.BIN') -Records @(@{ V40 = 1; V21 = 2 })
        $pwshPath = (Get-Process -Id $PID).Path
        $null = & $pwshPath -NoLogo -NoProfile -NonInteractive -File $launcher $log.FullName -NoPause 2>&1
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $TestDrive 'NCLog_pkg.csv') | Should -BeTrue
    }
}
