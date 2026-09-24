#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    $script:log = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_info.BIN') -TrailingBytes 3 -Records @(
        @{ V40 = 10.5; V21 = 1000 }
        @{ V40 = 20; V21 = 2000 }
        @{ V40 = 30; V21 = 3000 }
    )
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Get-NCLogFileInfo' {

    It 'サイズ・レコード数・端数バイトを返す' {
        $info = Get-NCLogFileInfo -Path $log.FullName
        $info.PSObject.TypeNames | Should -Contain 'NCLog.FileInfo'
        $info.Length | Should -Be (0x20 + 3 * 16 + 3)
        $info.RecordCount | Should -Be 3
        $info.TrailingBytes | Should -Be 3
    }

    It 'ヘッダーを16進と 4 byte ワードで返す' {
        $info = Get-NCLogFileInfo -Path $log.FullName
        $info.HeaderHex | Should -Be ('AB' * 0x20)
        $info.HeaderWords.Count | Should -Be 8
    }

    It 'サンプルレコードの各ワードを Int32 / Single で解釈する' {
        $info = Get-NCLogFileInfo -Path $log.FullName -SampleCount 2
        $info.Samples.Count | Should -Be 2
        $s1 = $info.Samples[1]
        $s1.FileOffset | Should -Be (0x20 + 16)
        $s1.Words.Count | Should -Be 4
        $s1.Words[0].Int32 | Should -Be 1                # レコード番号
        $s1.Words[1].Single | Should -Be 20               # ADD_40_0
        $s1.Words[2].Single | Should -Be 2000             # ADD_21_0
        $s1.Hex.Length | Should -Be 32
    }

    It 'SampleCount はレコード数で頭打ちになる' {
        (Get-NCLogFileInfo -Path $log.FullName -SampleCount 100).Samples.Count | Should -Be 3
    }

    It '仮定したレコード長で端数が出るかを確認できる' {
        (Get-NCLogFileInfo -Path $log.FullName -RecordSize 20).TrailingBytes | Should -Be ((3 * 16 + 3) % 20)
    }

    It 'ヘッダーより小さいファイルでも失敗しない' {
        $tiny = Join-Path $TestDrive 'tiny.BIN'
        [System.IO.File]::WriteAllBytes($tiny, [byte[]](1, 2, 3, 4, 5, 6))
        $info = Get-NCLogFileInfo -Path $tiny
        $info.RecordCount | Should -Be 0
        $info.HeaderHex | Should -Be '010203040506'
        $info.Samples.Count | Should -Be 0
    }

    It 'RecordSize は 4 の倍数のみ受け付ける' {
        { Get-NCLogFileInfo -Path $log.FullName -RecordSize 18 } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Get-NCLogFileInfo'
    }

    It 'パイプライン入力を受け付ける' {
        @(Get-ChildItem -LiteralPath $log.FullName | Get-NCLogFileInfo).Count | Should -Be 1
    }
}
