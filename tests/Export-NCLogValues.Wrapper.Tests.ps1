#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:wrapper = Join-Path $PSScriptRoot '..' 'Export-NCLogValues.ps1'
    $script:log = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_wrap.BIN') -Records @(
        @{ V40 = 2000; V21 = 1000.5 }
        @{ V40 = 1800; V21 = [double]::NaN }
        @{ V40 = 1500; V21 = 812.25 }
    )
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Export-NCLogValues.ps1 (互換ラッパー)' {

    It 'v1.0 と同じ -FilePath 指定で動く' {
        & $wrapper -FilePath $log.FullName -Format Raw | Should -Be @('0,2000,1000.5', '2,1500,812.25')
    }

    It 'モジュールの Export-NCLogValue と同じ結果を返す' {
        Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force
        $expected = Export-NCLogValue -Path $log.FullName -Format CSV
        & $wrapper -Path $log.FullName -Format CSV | Should -Be $expected
    }

    It 'パイプライン入力 (FileInfo) を渡せる' {
        $r = @(Get-ChildItem -LiteralPath $log.FullName | & $wrapper -AsObject)
        $r.Count | Should -Be 2
        $r[1].RecordNumber | Should -Be 2
    }

    It '-WhatIf を内部コマンドに伝える' {
        $out = Join-Path $TestDrive 'wrap.csv'
        & $wrapper -Path $log.FullName -OutputPath $out -WhatIf
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It '終了エラーを呼び出し元に伝える' {
        $out = Join-Path $TestDrive 'exists.csv'
        Set-Content -LiteralPath $out -Value 'x'
        { & $wrapper -Path $log.FullName -OutputPath $out } | Should -Throw -ErrorId 'OutputFileExists,Export-NCLogValue'
    }

    It 'パラメーター定義がモジュールの Export-NCLogValue と一致する' {
        Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
            [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $wrapperParams = (Get-Command $wrapper).Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object
        $moduleParams = (Get-Command Export-NCLogValue).Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object
        $wrapperParams | Should -Be $moduleParams
    }
}
