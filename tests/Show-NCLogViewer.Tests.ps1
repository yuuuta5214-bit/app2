#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# ウィンドウ (Start-NCLogViewerWindow) は Mock に置き換え、引数の受け渡しとエラー処理だけを検証する。
# WPF の画面自体は CI で表示できないため、手動で確認する。

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    $script:log = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_view.BIN') -Records @(@{ V40 = 1; V21 = 2 })
    $null = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog_view2.BIN') -Records @(@{ V40 = 3; V21 = 4 })
    $script:bracket = New-NCLogTestFile -Path (Join-Path $TestDrive 'NCLog[1].BIN') -Records @(@{ V40 = 5; V21 = 6 })
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Show-NCLogViewer' {

    BeforeEach {
        Mock -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -MockWith { }
    }

    Context '入力検証 (全 OS)' {
        It '存在しないパスはエラーにし、ウィンドウを開かない' {
            Show-NCLogViewer -Path (Join-Path $TestDrive 'missing.BIN') -ErrorVariable err -ErrorAction SilentlyContinue
            $err[0].FullyQualifiedErrorId | Should -Be 'PathNotFound,Show-NCLogViewer'
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 0 -Exactly
        }

        It 'フォルダを指定するとエラー' {
            Show-NCLogViewer -LiteralPath $TestDrive -ErrorVariable err -ErrorAction SilentlyContinue
            $err[0].FullyQualifiedErrorId | Should -Be 'FileNotFound,Show-NCLogViewer'
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 0 -Exactly
        }

        It 'ワイルドカードが複数ファイルに一致したら終了エラー' {
            { Show-NCLogViewer -Path (Join-Path $TestDrive 'NCLog_view*.BIN') } |
                Should -Throw -ErrorId 'MultipleFilesNotSupported,Show-NCLogViewer'
        }

        It 'レイアウトが不正なら終了エラー' {
            { Show-NCLogViewer -Path $log.FullName -RecordSize 8 -Value21Offset 8 } |
                Should -Throw -ErrorId 'InvalidRecordLayout,Show-NCLogViewer'
        }

        It 'パラメーターの範囲検証' {
            { Show-NCLogViewer -RecordSize 4 } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Show-NCLogViewer'
        }
    }

    Context 'Windows 以外' -Skip:$IsWindows {
        It 'Windows 専用であることを示す終了エラー' {
            { Show-NCLogViewer -Path $log.FullName } | Should -Throw -ErrorId 'ViewerRequiresWindows,Show-NCLogViewer'
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 0 -Exactly
        }
    }

    Context 'Windows' -Skip:(-not $IsWindows) {
        It '解決した絶対パスとレイアウトをウィンドウに渡す' {
            Push-Location -LiteralPath $TestDrive
            try {
                Show-NCLogViewer -Path '.\NCLog_view.BIN' -HeaderSize 0x20 -RecordSize 16 -Value40Offset 8 -Value21Offset 4
            }
            finally {
                Pop-Location
            }
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                $LiteralFilePath -eq $log.FullName -and $HeaderSize -eq 0x20 -and $RecordSize -eq 16 -and
                $Value40Offset -eq 8 -and $Value21Offset -eq 4
            }
        }

        It 'LiteralPath は [ ] を含むファイル名をそのまま開く' {
            Show-NCLogViewer -LiteralPath $bracket.FullName
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                $LiteralFilePath -eq $bracket.FullName
            }
        }

        It 'パス省略時はファイルなしで既定レイアウトのウィンドウを開く' {
            Show-NCLogViewer
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                [string]::IsNullOrEmpty($LiteralFilePath) -and $HeaderSize -eq 0x20 -and $RecordSize -eq 16 -and
                $Value40Offset -eq 4 -and $Value21Offset -eq 8
            }
        }

        It 'ウィンドウの失敗は ViewerFailed の終了エラーになる' {
            Mock -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -MockWith {
                throw [System.InvalidOperationException]::new('STA ではありません')
            }
            { Show-NCLogViewer -Path $log.FullName } | Should -Throw -ErrorId 'ViewerFailed,Show-NCLogViewer'
        }

        It '同梱の XAML は WPF で読み込め、画面処理が参照する要素がすべてある' {
            $sta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
            if (-not $sta) { Set-ItResult -Skipped -Because 'WPF の読み込みには STA スレッドが必要' ; return }

            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $moduleRoot = Join-Path $PSScriptRoot '..' 'NCLogTools'
            $xaml = [System.IO.File]::ReadAllText((Join-Path $moduleRoot 'Viewer' 'NCLogViewer.xaml'), [System.Text.Encoding]::UTF8)
            $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
            try {
                $code = Get-Content -LiteralPath (Join-Path $moduleRoot 'Viewer' 'Start-NCLogViewerWindow.ps1') -Raw
                $block = [regex]::Match($code, "(?s)foreach \(\`$name in @\((.*?)\)\) \{").Groups[1].Value
                $names = [regex]::Matches($block, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value }
                $names.Count | Should -BeGreaterThan 30
                foreach ($name in $names) {
                    $window.FindName($name) | Should -Not -BeNullOrEmpty -Because "x:Name=$name"
                }
            }
            finally {
                $window.Close()
            }
        }
    }
}
