#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $root = Join-Path $PSScriptRoot '..'
    Import-Module (Join-Path $root 'NCLogTools' 'NCLogTools.psd1') -Force
    $script:publicCommands = @(Get-Command -Module NCLogTools | ForEach-Object { @{ Name = $_.Name } })
    $script:scriptFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $root 'NCLogTools') -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File
        Get-Item -LiteralPath (Join-Path $root 'Export-NCLogValues.ps1')
        Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' -File
        Get-ChildItem -LiteralPath (Join-Path $root 'build') -Filter '*.ps1' -File
    ) | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
    $script:hasAnalyzer = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
}

BeforeAll {
    $script:root = Join-Path $PSScriptRoot '..'
    $script:manifestPath = Join-Path $root 'NCLogTools' 'NCLogTools.psd1'
    Import-Module $manifestPath -Force
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'NCLogTools モジュール' {

    It 'マニフェストが有効' {
        { Test-ModuleManifest -Path $manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It '公開コマンドはマニフェストの FunctionsToExport と一致する' {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
        (Get-Command -Module NCLogTools).Name | Sort-Object | Should -Be ($manifest.FunctionsToExport | Sort-Object)
    }

    It '内部関数は公開しない' {
        Get-Command -Module NCLogTools -Name 'Resolve-NCLogPath' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    Context '<Name>' -ForEach $publicCommands {
        It '承認された動詞を使う' {
            $verb = ($Name -split '-')[0]
            (Get-Verb).Verb | Should -Contain $verb
        }

        It '名詞は単数形 (NCLog 接頭辞付き)' {
            ($Name -split '-')[1] | Should -Match '^NCLog[A-Z][A-Za-z]*[^s]$'
        }

        It 'コメントベースのヘルプ (Synopsis / Description / Example) がある' {
            $help = Get-Help -Name $Name -Full
            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -BeLike "*$Name*[<]*"
            $help.description | Should -Not -BeNullOrEmpty
            @($help.examples.example).Count | Should -BeGreaterOrEqual 1
        }

        It 'すべてのパラメーターに説明がある' {
            $help = Get-Help -Name $Name -Full
            $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
            foreach ($p in (Get-Command $Name).Parameters.Keys | Where-Object { $_ -notin $common }) {
                $doc = $help.parameters.parameter | Where-Object Name -EQ $p
                $doc.description | Should -Not -BeNullOrEmpty -Because "パラメーター $p の説明"
            }
        }
    }

    Context 'スクリプト品質: <Name>' -ForEach $scriptFiles {
        It '構文エラーがない' {
            $tokens = $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }

        It 'Invoke-Expression を使わない' {
            (Get-Content -LiteralPath $Path -Raw) | Should -Not -Match '\bInvoke-Expression\b|\biex\b'
        }

        It 'PSScriptAnalyzer の警告・エラーがない' -Skip:(-not $hasAnalyzer) {
            $settings = Join-Path $PSScriptRoot '..' 'PSScriptAnalyzerSettings.psd1'
            $result = Invoke-ScriptAnalyzer -Path $Path -Settings $settings
            $result | ForEach-Object { "$($_.RuleName) L$($_.Line): $($_.Message)" } | Should -BeNullOrEmpty
        }
    }
}
