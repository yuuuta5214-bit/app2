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

        It 'レイアウトが不正なら終了エラー' {
            { Show-NCLogViewer -Path $log.FullName -RecordSize 8 -Value21Offset 8 } |
                Should -Throw -ErrorId 'InvalidRecordLayout,Show-NCLogViewer'
        }

        It 'パラメーターの範囲検証' {
            { Show-NCLogViewer -RecordSize 4 } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Show-NCLogViewer'
        }
    }

    Context '画面定義 (XAML) と画面処理の対応 (全 OS)' {
        BeforeAll {
            $moduleRoot = Join-Path $PSScriptRoot '..' 'NCLogTools'
            $script:xamlText = Get-Content -LiteralPath (Join-Path $moduleRoot 'Viewer' 'NCLogViewer.xaml') -Raw
            $script:viewerCode = Get-Content -LiteralPath (Join-Path $moduleRoot 'Viewer' 'Start-NCLogViewerWindow.ps1') -Raw
            $block = [regex]::Match($viewerCode, "(?s)foreach \(\`$name in @\((.*?)\)\) \{").Groups[1].Value
            $script:registered = @([regex]::Matches($block, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
        }

        It 'XAML は整形式の XML' {
            { [xml]$xamlText } | Should -Not -Throw
        }

        It '画面処理が使う要素はすべて登録済みで、XAML にある' {
            $names = @([regex]::Matches($xamlText, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
            $registered.Count | Should -BeGreaterThan 30
            $registered | Where-Object { $_ -notin $names } | Should -BeNullOrEmpty
            $used = @([regex]::Matches($viewerCode, '(?:\$ui|\$ctx\.UI|\$Context\.UI)\.(\w+)') |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $used | Where-Object { $_ -notin $registered } | Should -BeNullOrEmpty
        }

        It '16進ダンプ・ファイル情報のタブは既定で非表示 ([ツール] メニューで表示)' {
            $xamlText | Should -Match '<TabItem x:Name="HexTab"[^>]*Visibility="Collapsed"'
            $xamlText | Should -Match '<TabItem x:Name="InfoTab"[^>]*Visibility="Collapsed"'
            $xamlText | Should -Match 'x:Name="MenuShowHex"[^>]*IsCheckable="True"'
            $xamlText | Should -Match 'x:Name="MenuShowInfo"[^>]*IsCheckable="True"'
        }

        It 'グラフの値の取得は右クリック (左ボタンはドラッグ・ダブルクリック専用)' {
            $viewerCode | Should -Match 'Add_MouseRightButtonUp\(\{(?s:.*?)Set-NCLogViewerPickedRecord'
            $leftUp = [regex]::Match($viewerCode, '(?s)Add_MouseLeftButtonUp\(\{(.*?)\}\)').Groups[1].Value
            $leftUp | Should -Not -BeNullOrEmpty
            $leftUp | Should -Not -Match 'Set-NCLogViewerPickedRecord'
        }

        It 'ドロップのイベント中には読み込まない (ドロップ元のエクスプローラーごと固まるため)' {
            $drop = [regex]::Match($viewerCode, '(?s)\$window\.Add_Drop\(\{(.*?)\n        \}\)').Groups[1].Value
            $drop | Should -Not -BeNullOrEmpty
            $drop | Should -Match 'Request-NCLogViewerOpen'
            $drop | Should -Not -Match 'Add-NCLogViewerFile'
            $drop | Should -Not -Match 'Show-NCLogViewerProgress'
            # 予約した読み込みは Dispatcher の次の処理で行う
            $request = [regex]::Match($viewerCode, '(?s)function Request-NCLogViewerOpen \{(.*?)\n\}').Groups[1].Value
            $request | Should -Match 'BeginInvoke\(\[System\.Windows\.Threading\.DispatcherPriority\]::Background'
            $request | Should -Match 'Add-NCLogViewerFile'
        }

        It '起動時に指定されたファイルも、準備 (C# のコンパイル) の後に予約して開く' {
            $rendered = [regex]::Match($viewerCode, '(?s)\$window\.Add_ContentRendered\(\{(.*?)\n        \}\)').Groups[1].Value
            $rendered | Should -Match 'Test-NCLogNative'
            $rendered | Should -Match 'Request-NCLogViewerOpen'
            $rendered | Should -Not -Match 'Add-NCLogViewerFile'
        }

        It 'レーザー出力の単位は W で表示する' {
            $xamlText | Should -Match 'ADD_40_0 レーザー出力 \(W\)'
            $xamlText | Should -Not -Match 'レーザー出力 \(%\)'
        }

        It '画面処理が呼ぶ NCLog 関数はすべてモジュール内にある' {
            $all = (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..' 'NCLogTools') -Recurse -Filter '*.ps1' |
                    Get-Content -Raw) -join "`n"
            $defined = @([regex]::Matches($all, '(?m)^function ([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
            $called = @([regex]::Matches($viewerCode, '\b([A-Z][a-z]+-NCLog\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $called | Where-Object { $_ -notin $defined } | Should -BeNullOrEmpty
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
                Show-NCLogViewer -Path '.\NCLog_view.BIN' -HeaderSize 0x40 -RecordSize 24 -Value40Offset 2 -Value21Offset 16
            }
            finally {
                Pop-Location
            }
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                $LiteralFilePath.Count -eq 1 -and $LiteralFilePath[0] -eq $log.FullName -and $HeaderSize -eq 0x40 -and $RecordSize -eq 24 -and
                $Value40Offset -eq 2 -and $Value21Offset -eq 16
            }
        }

        It 'ワイルドカードに一致したファイルをすべて (重複なしで) ウィンドウに渡す' {
            Show-NCLogViewer -Path (Join-Path $TestDrive 'NCLog_view*.BIN'), $log.FullName
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                $LiteralFilePath.Count -eq 2 -and $LiteralFilePath[0] -eq $log.FullName -and
                $LiteralFilePath[1] -eq (Join-Path $TestDrive 'NCLog_view2.BIN')
            }
        }

        It '一部のパスが見つからなくても、エラーを報告して残りを開く' {
            Show-NCLogViewer -LiteralPath (Join-Path $TestDrive 'missing.BIN'), $log.FullName -ErrorVariable err -ErrorAction SilentlyContinue
            $err[0].FullyQualifiedErrorId | Should -Be 'PathNotFound,Show-NCLogViewer'
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                $LiteralFilePath.Count -eq 1 -and $LiteralFilePath[0] -eq $log.FullName
            }
        }

        It 'LiteralPath は [ ] を含むファイル名をそのまま開く' {
            Show-NCLogViewer -LiteralPath $bracket.FullName
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                $LiteralFilePath.Count -eq 1 -and $LiteralFilePath[0] -eq $bracket.FullName
            }
        }

        It 'パス省略時はファイルなしで既定レイアウトのウィンドウを開く' {
            Show-NCLogViewer
            Should -Invoke -ModuleName NCLogTools -CommandName Start-NCLogViewerWindow -Times 1 -Exactly -ParameterFilter {
                @($LiteralFilePath).Count -eq 0 -and $HeaderSize -eq 0 -and $RecordSize -eq 368 -and
                $Value40Offset -eq 328 -and $Value21Offset -eq 160
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
