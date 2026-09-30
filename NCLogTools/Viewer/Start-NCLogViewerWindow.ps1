<#
    NCLog Viewer の画面処理 (WPF)。Windows 専用。

    Show-NCLogViewer から呼ばれる内部関数群。画面に依存しない処理 (解析・統計・グラフ座標・
    16進表示の行生成・出力ファイル名・一括 CSV 出力) は Private フォルダにあり、Pester で単体テストしている。
    このファイルは WPF の部品を操作するだけに留める。

    状態は $ctx (hashtable) に集約し、各関数へ -Context で渡す:
        $ctx.Window / $ctx.UI.<x:Name>       画面部品
        $ctx.Files                           開いているファイル (NCLogViewerFile の ObservableCollection)
        $ctx.Current                         選択中のファイル (NCLogViewerFile。なければ $null)
        $ctx.Data                            選択中のファイルの解析結果 (New-NCLogViewData)
        $ctx.HexList / $ctx.RecordList       DataGrid に渡した遅延生成リスト
        $ctx.ViewStart / $ctx.ViewEnd        グラフの表示範囲 (レコード番号)
        $ctx.Suppress                        画面をプログラムから更新している間は $true (イベントの再入防止)
#>

function Start-NCLogViewerWindow {
    <#
    .SYNOPSIS
        NCLog Viewer のウィンドウを表示し、閉じられるまで待つ。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'ウィンドウを表示するだけで、システムの状態は変更しない')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'イベントハンドラーは WPF のシグネチャ (sender, e) で受ける。LiteralFilePath は ContentRendered のハンドラー内で使う')]
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$LiteralFilePath,
        [Parameter(Mandatory)][int]$HeaderSize,
        [Parameter(Mandatory)][int]$RecordSize,
        [Parameter(Mandatory)][int]$Value40Offset,
        [Parameter(Mandatory)][int]$Value21Offset
    )

    # WPF は STA スレッドが必須 (pwsh は Windows では既定で STA。-MTA 起動時などに備えて確認する)
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        throw [System.InvalidOperationException]::new(
            'ビューアーは STA スレッドで実行する必要があります。pwsh -STA で起動するか、NCLogViewer.cmd を使ってください。')
    }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    # XAML は任意の型を生成できるため、モジュールに同梱したファイル以外は読み込まない
    $xamlPath = Join-Path -Path $PSScriptRoot -ChildPath 'NCLogViewer.xaml'
    $xaml = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

    $ui = @{}
    foreach ($name in @(
            'MenuOpen', 'MenuRemove', 'MenuRemoveAll', 'MenuBatchExport', 'MenuExport', 'MenuExit',
            'MenuShowHex', 'MenuShowInfo', 'MenuShowLayout', 'MenuHowTo', 'MenuAbout',
            'OpenButton', 'ToolbarBatchExportButton', 'LayoutBar',
            'HeaderSizeBox', 'RecordSizeBox', 'Value40OffsetBox', 'Value21OffsetBox', 'ApplyLayoutButton', 'ResetLayoutButton',
            'StatusText', 'SelectionText',
            'FileGrid', 'AddButton', 'RemoveButton', 'FileCountText',
            'NameGroup', 'SelectedFileText', 'LaserBox', 'WireBox', 'RatioBox', 'PickedText', 'OutputNameText',
            'OutputDirBox', 'BrowseOutputDirButton', 'ClearOutputDirButton', 'BatchExportButton', 'BatchSummaryText',
            'MainTabs', 'ChartTab', 'RecordTab', 'HexTab', 'InfoTab',
            'RecordJumpBox', 'RecordJumpButton', 'RecordGrid', 'HexGrid', 'OffsetBox', 'OffsetJumpButton', 'InspectorGrid',
            'RangeStartBox', 'RangeEndBox', 'RangeApplyButton', 'RangeResetButton', 'HoverText', 'AxisStartText', 'AxisEndText',
            'Chart40Canvas', 'Chart40MaxText', 'Chart40MinText', 'Chart21Canvas', 'Chart21MaxText', 'Chart21MinText',
            'ChartEmptyText', 'FileInfoGrid', 'StatisticsGrid', 'HeaderGrid'
        )) {
        $element = $window.FindName($name)
        if ($null -eq $element) { throw "XAML に要素 '$name' がありません: $xamlPath" }
        $ui[$name] = $element
    }

    $ctx = @{
        Window        = $window
        UI            = $ui
        Files         = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
        Current       = $null
        Data          = $null
        HexList       = $null
        RecordList    = $null
        ViewStart     = 0
        ViewEnd       = 0
        Drag          = $null
        Suppress      = $false
        PendingOffset = 0L
        DefaultLayout = @{
            HeaderSize    = $HeaderSize
            RecordSize    = $RecordSize
            Value40Offset = $Value40Offset
            Value21Offset = $Value21Offset
        }
        Cursor40      = $null
        Cursor21      = $null
    }
    Set-NCLogViewerLayoutText -Context $ctx -Layout $ctx.DefaultLayout
    $ui.FileGrid.ItemsSource = $ctx.Files

    # --- イベント登録 -------------------------------------------------------------
    # ハンドラーはこの関数の中から ShowDialog で呼ばれるため、$ctx をそのまま参照できる。
    # 例外が WPF のメッセージループまで届くとプロセスが落ちるので、必ず Invoke-NCLogViewerAction を通す。
    $openHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Open-NCLogViewerFileDialog -Context $ctx } }
    $exportHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Export-NCLogViewerCsv -Context $ctx } }
    $batchHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Export-NCLogViewerBatchCsv -Context $ctx } }
    $removeHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Remove-NCLogViewerFile -Context $ctx } }
    $applyHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Update-NCLogViewerLayout -Context $ctx } }
    $howToHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Show-NCLogViewerHowTo -Context $ctx } }

    $ui.MenuOpen.Add_Click($openHandler)
    $ui.OpenButton.Add_Click($openHandler)
    $ui.AddButton.Add_Click($openHandler)
    $ui.MenuExport.Add_Click($exportHandler)
    $ui.MenuBatchExport.Add_Click($batchHandler)
    $ui.BatchExportButton.Add_Click($batchHandler)
    $ui.ToolbarBatchExportButton.Add_Click($batchHandler)
    $ui.MenuRemove.Add_Click($removeHandler)
    $ui.RemoveButton.Add_Click($removeHandler)
    $ui.MenuRemoveAll.Add_Click({ Invoke-NCLogViewerAction -Context $ctx -Action { Remove-NCLogViewerFile -Context $ctx -All } })
    $ui.ApplyLayoutButton.Add_Click($applyHandler)
    $ui.MenuHowTo.Add_Click($howToHandler)
    $ui.MenuExit.Add_Click({ $ctx.Window.Close() })
    $ui.MenuAbout.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $module = Get-Module -Name NCLogTools
                $version = if ($module) { $module.Version } else { '?' }
                Show-NCLogViewerMessage -Context $ctx -Icon Information -Message (
                    "NCLog Viewer (NCLogTools $version)`n`nワイヤレーザー3Dプリンターの NCLog バイナリ (.BIN) を閲覧し、`n" +
                    "ファイルごとに名前を付けて CSV に一括出力します。`n" +
                    "BIN ファイルは読み取り専用で開き、変更しません。")
            }
        })

    # [ツール] メニュー: 16進ダンプ・ファイル情報・レイアウト設定は必要なときだけ表示する
    $ui.MenuShowHex.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                Set-NCLogViewerToolTab -Context $ctx -Tab $ctx.UI.HexTab -Visible $ctx.UI.MenuShowHex.IsChecked
            }
        })
    $ui.MenuShowInfo.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                Set-NCLogViewerToolTab -Context $ctx -Tab $ctx.UI.InfoTab -Visible $ctx.UI.MenuShowInfo.IsChecked
            }
        })
    $ui.MenuShowLayout.Add_Click({
            $ctx.UI.LayoutBar.Visibility = if ($ctx.UI.MenuShowLayout.IsChecked) {
                [System.Windows.Visibility]::Visible
            }
            else {
                [System.Windows.Visibility]::Collapsed
            }
        })

    $ui.ResetLayoutButton.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                Set-NCLogViewerLayoutText -Context $ctx -Layout $ctx.DefaultLayout
                if ($ctx.Files.Count -gt 0) { Update-NCLogViewerLayout -Context $ctx }
            }
        })
    foreach ($box in $ui.HeaderSizeBox, $ui.RecordSizeBox, $ui.Value40OffsetBox, $ui.Value21OffsetBox) {
        $box.Add_KeyDown({
                param($s, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $ctx.Files.Count -gt 0) {
                    $e.Handled = $true
                    Invoke-NCLogViewerAction -Context $ctx -Action { Update-NCLogViewerLayout -Context $ctx }
                }
            })
    }

    # ショートカットキー
    $window.Add_PreviewKeyDown({
            param($s, $e)
            $modifiers = [System.Windows.Input.Keyboard]::Modifiers
            $control = [System.Windows.Input.ModifierKeys]::Control
            $shift = [System.Windows.Input.ModifierKeys]::Shift
            if ($e.Key -eq [System.Windows.Input.Key]::F1) {
                $e.Handled = $true
                & $howToHandler
            }
            elseif ($modifiers -eq $control -and $e.Key -eq [System.Windows.Input.Key]::O) {
                $e.Handled = $true
                & $openHandler
            }
            elseif ($modifiers -eq $control -and $e.Key -eq [System.Windows.Input.Key]::E -and $null -ne $ctx.Data) {
                $e.Handled = $true
                & $exportHandler
            }
            elseif ($modifiers -eq ($control -bor $shift) -and $e.Key -eq [System.Windows.Input.Key]::E) {
                $e.Handled = $true
                & $batchHandler
            }
        })

    # ドラッグ＆ドロップ (複数ファイル・フォルダ可)
    $window.Add_PreviewDragOver({
            param($s, $e)
            $e.Effects = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
                [System.Windows.DragDropEffects]::Copy
            }
            else {
                [System.Windows.DragDropEffects]::None
            }
            $e.Handled = $true
        })
    $window.Add_Drop({
            param($s, $e)
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $dropped = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
                if ($dropped.Count -gt 0) { Add-NCLogViewerFile -Context $ctx -Path ([string[]]$dropped) }
            }
        })

    # ① ファイル一覧
    $ui.FileGrid.Add_SelectionChanged({
            if ($ctx.Suppress) { return }
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $selected = $ctx.UI.FileGrid.SelectedItem
                if ($null -ne $selected -and -not [object]::ReferenceEquals($selected, $ctx.Current)) {
                    Select-NCLogViewerFile -Context $ctx -File $selected
                }
            }
        })
    $ui.FileGrid.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Delete) {
                $e.Handled = $true
                & $removeHandler
            }
        })

    # ②③ 出力ファイル名の入力。入力のたびに出力ファイル名と状態を計算し直す
    $ui.LaserBox.Add_TextChanged({
            if ($ctx.Suppress -or $null -eq $ctx.Current) { return }
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $ctx.Current.LaserText = $ctx.UI.LaserBox.Text
                Update-NCLogViewerFileList -Context $ctx
            }
        })
    $ui.WireBox.Add_TextChanged({
            if ($ctx.Suppress -or $null -eq $ctx.Current) { return }
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $ctx.Current.WireText = $ctx.UI.WireBox.Text
                Update-NCLogViewerFileList -Context $ctx
            }
        })
    $ui.RatioBox.Add_TextChanged({
            if ($ctx.Suppress -or $null -eq $ctx.Current) { return }
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $ctx.Current.RatioText = $ctx.UI.RatioBox.Text
                Update-NCLogViewerFileList -Context $ctx
            }
        })
    # 割合で Enter → 次のファイルへ (続けて割合を入力できる)
    $ui.RatioBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -ne [System.Windows.Input.Key]::Enter) { return }
            $e.Handled = $true
            Invoke-NCLogViewerAction -Context $ctx -Action { Select-NCLogViewerNextFile -Context $ctx }
        })
    foreach ($pair in @(@($ui.LaserBox, $ui.WireBox), @($ui.WireBox, $ui.RatioBox))) {
        $next = $pair[1]
        $pair[0].Add_KeyDown({
                param($s, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                    $e.Handled = $true
                    [void]$next.Focus()
                    $next.SelectAll()
                }
            }.GetNewClosure())
    }

    # ④ 一括 CSV 出力の出力先
    $ui.OutputDirBox.Add_TextChanged({
            if ($ctx.Suppress) { return }
            Invoke-NCLogViewerAction -Context $ctx -Action { Update-NCLogViewerFileList -Context $ctx }
        })
    $ui.BrowseOutputDirButton.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action { Select-NCLogViewerOutputDirectory -Context $ctx }
        })
    $ui.ClearOutputDirButton.Add_Click({ $ctx.UI.OutputDirBox.Text = '' })

    # レコード表
    $recordJump = {
        Invoke-NCLogViewerAction -Context $ctx -Action {
            if ($null -eq $ctx.RecordList) { return }
            $n = ConvertFrom-NCLogNumberText -Text $ctx.UI.RecordJumpBox.Text -Name 'レコード番号'
            if ($n -ge $ctx.RecordList.Count) {
                throw [System.ArgumentOutOfRangeException]::new('RecordNumber', $n,
                    "レコード番号は 0 ～ $($ctx.RecordList.Count - 1) の範囲で指定してください。")
            }
            $item = $ctx.RecordList.get_Item([int]$n)
            $ctx.UI.RecordGrid.SelectedItem = $item
            $ctx.UI.RecordGrid.ScrollIntoView($item)
            [void]$ctx.UI.RecordGrid.Focus()
        }
    }
    $ui.RecordJumpButton.Add_Click($recordJump)
    $ui.RecordJumpBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter) { $e.Handled = $true; & $recordJump }
        })
    $ui.RecordGrid.Add_SelectionChanged({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $row = $ctx.UI.RecordGrid.SelectedItem
                if ($null -eq $row) { return }
                $ctx.UI.SelectionText.Text = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture,
                    'No.{0}  0x{1}  ADD_40_0={2:0.######}  ADD_21_0={3:0.######}',
                    $row.RecordNumber, $row.Address, $row.Value40, $row.Value21)
            }
        })
    $ui.RecordGrid.Add_MouseDoubleClick({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $row = $ctx.UI.RecordGrid.SelectedItem
                if ($null -eq $row) { return }
                $ctx.PendingOffset = $row.Offset + $ctx.Data.Value40Offset
                # 16進ダンプを非表示にしていても、ダブルクリックしたら表示する
                Set-NCLogViewerToolTab -Context $ctx -Tab $ctx.UI.HexTab -Visible $true
                # 初めて表示するタブは DataGrid の生成前でスクロールできないため、描画後に移動する
                [void]$ctx.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [Action]{
                        Invoke-NCLogViewerAction -Context $ctx -Action {
                            Select-NCLogViewerHexOffset -Context $ctx -Offset $ctx.PendingOffset
                        }
                    })
            }
        })

    # 16進ダンプ
    $ui.HexGrid.Add_CurrentCellChanged({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $cell = $ctx.UI.HexGrid.CurrentCell
                if ($null -eq $cell.Item -or $null -eq $cell.Column -or $null -eq $cell.Item.PSObject.Properties['Offset']) { return }
                # 列 2..17 が 00..0F。アドレス・Rec・ASCII 列は行の先頭バイトとして扱う
                $column = $ctx.UI.HexGrid.Columns.IndexOf($cell.Column)
                $byteIndex = if ($column -ge 2 -and $column -le 17) { $column - 2 } else { 0 }
                Update-NCLogViewerInspector -Context $ctx -Offset ($cell.Item.Offset + $byteIndex)
            }
        })
    $offsetJump = {
        Invoke-NCLogViewerAction -Context $ctx -Action {
            if ($null -eq $ctx.Data) { return }
            $offset = ConvertFrom-NCLogNumberText -Text $ctx.UI.OffsetBox.Text -Name 'オフセット'
            Select-NCLogViewerHexOffset -Context $ctx -Offset $offset
        }
    }
    $ui.OffsetJumpButton.Add_Click($offsetJump)
    $ui.OffsetBox.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter) { $e.Handled = $true; & $offsetJump }
        })

    # グラフ
    $ui.RangeApplyButton.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                if ($null -eq $ctx.Data -or $ctx.Data.RecordCount -eq 0) { return }
                $start = ConvertFrom-NCLogNumberText -Text $ctx.UI.RangeStartBox.Text -Name '開始レコード'
                $end = ConvertFrom-NCLogNumberText -Text $ctx.UI.RangeEndBox.Text -Name '終了レコード'
                if ($end -le $start) { throw [System.ArgumentException]::new('終了レコードは開始レコードより大きい値を指定してください。') }
                Set-NCLogViewerChartRange -Context $ctx -Start $start -End $end
            }
        })
    $ui.RangeResetButton.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                if ($null -eq $ctx.Data) { return }
                Set-NCLogViewerChartRange -Context $ctx -Start 0 -End ($ctx.Data.RecordCount - 1)
            }
        })
    foreach ($canvas in $ui.Chart40Canvas, $ui.Chart21Canvas) {
        $canvas.Add_SizeChanged({ Invoke-NCLogViewerAction -Context $ctx -Action { Update-NCLogViewerChart -Context $ctx } })
        $canvas.Add_MouseWheel({
                param($s, $e)
                Invoke-NCLogViewerAction -Context $ctx -Action {
                    if ($null -eq $ctx.Data -or $ctx.Data.RecordCount -lt 2) { return }
                    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, $e.GetPosition($s).X / [Math]::Max(1.0, $s.ActualWidth)))
                    $count = $ctx.ViewEnd - $ctx.ViewStart
                    $newCount = if ($e.Delta -gt 0) { [Math]::Max(10, [Math]::Floor($count * 0.8)) } else { [Math]::Ceiling($count * 1.25) + 1 }
                    $anchor = $ctx.ViewStart + $ratio * $count
                    $start = [Math]::Round($anchor - $ratio * $newCount)
                    Set-NCLogViewerChartRange -Context $ctx -Start $start -End ($start + $newCount)
                    $e.Handled = $true
                }
            })
        $canvas.Add_MouseLeftButtonDown({
                param($s, $e)
                Invoke-NCLogViewerAction -Context $ctx -Action {
                    $ctx.Drag = $null
                    if ($null -eq $ctx.Data -or $ctx.Data.RecordCount -eq 0) { return }
                    if ($e.ClickCount -ge 2) {
                        Set-NCLogViewerChartRange -Context $ctx -Start 0 -End ($ctx.Data.RecordCount - 1)
                        return
                    }
                    $ctx.Drag = @{ X = $e.GetPosition($s).X; Start = $ctx.ViewStart; End = $ctx.ViewEnd }
                    [void]$s.CaptureMouse()
                }
            })
        $canvas.Add_MouseLeftButtonUp({
                param($s, $e)
                $ctx.Drag = $null
                $s.ReleaseMouseCapture()
            })
        # 右クリック: その位置のレーザー出力・ワイヤ速度を出力ファイル名の値として取得する
        # (左ボタンはドラッグ・ダブルクリックに使うため、誤って値が変わらないよう右ボタンに分けている)
        $canvas.Add_MouseRightButtonUp({
                param($s, $e)
                $e.Handled = $true
                Invoke-NCLogViewerAction -Context $ctx -Action {
                    if ($null -eq $ctx.Data -or $ctx.Data.RecordCount -eq 0) { return }
                    $index = Get-NCLogChartIndex -X $e.GetPosition($s).X -Width $s.ActualWidth `
                        -Start $ctx.ViewStart -End $ctx.ViewEnd -RecordCount $ctx.Data.RecordCount
                    Set-NCLogViewerPickedRecord -Context $ctx -Index $index
                }
            })
        $canvas.Add_MouseMove({
                param($s, $e)
                Invoke-NCLogViewerAction -Context $ctx -Action {
                    if ($null -eq $ctx.Data -or $ctx.Data.RecordCount -eq 0) { return }
                    $x = $e.GetPosition($s).X
                    $width = [Math]::Max(1.0, $s.ActualWidth)
                    $drag = $ctx.Drag
                    if ($null -ne $drag -and $e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
                        $shift = [Math]::Round(($drag.X - $x) / $width * ($drag.End - $drag.Start))
                        Set-NCLogViewerChartRange -Context $ctx -Start ($drag.Start + $shift) -End ($drag.End + $shift)
                    }
                    Update-NCLogViewerChartCursor -Context $ctx -X $x -Width $width
                }
            })
        $canvas.Add_MouseLeave({
                foreach ($line in $ctx.Cursor40, $ctx.Cursor21) {
                    if ($null -ne $line) { $line.Visibility = [System.Windows.Visibility]::Hidden }
                }
            })
    }

    # 予期しない例外でウィンドウごと落ちないようにする (通常は Invoke-NCLogViewerAction で処理済み)
    $window.Dispatcher.Add_UnhandledException({
            param($s, $e)
            $e.Handled = $true
            Show-NCLogViewerMessage -Context $ctx -Icon Error -Message "予期しないエラーが発生しました。`n$($e.Exception.Message)"
        })

    $window.Add_ContentRendered({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                [void]$ctx.Window.Activate()
                Update-NCLogViewerFileList -Context $ctx
                $targets = @($LiteralFilePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($targets.Count -gt 0) { Add-NCLogViewerFile -Context $ctx -Path $targets }
            }
        })

    [void]$window.ShowDialog()
}

function Get-NCLogViewerErrorMessage {
    <#
    .SYNOPSIS
        例外から画面に表示するメッセージを取り出す (MethodInvocationException は中身を使う)。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $ex = $ErrorRecord.Exception
    while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) {
        $ex = $ex.InnerException
    }
    $ex.Message
}

function Invoke-NCLogViewerAction {
    <#
    .SYNOPSIS
        画面操作の処理を実行し、例外はメッセージボックスで知らせる。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    try {
        & $Action
    }
    catch {
        Write-Verbose ($_ | Out-String)
        Show-NCLogViewerMessage -Context $Context -Icon Warning -Message (Get-NCLogViewerErrorMessage -ErrorRecord $_)
    }
}

function Show-NCLogViewerMessage {
    <#
    .SYNOPSIS
        ビューアーのウィンドウを親にしてメッセージボックスを表示する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )

    [void][System.Windows.MessageBox]::Show($Context.Window, $Message, 'NCLog Viewer',
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]$Icon)
}

function Show-NCLogViewerQuestion {
    <#
    .SYNOPSIS
        はい / いいえ (/ キャンセル) で確認し、押されたボタン (Yes / No / Cancel) を返す。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Message,
        [switch]$WithCancel
    )

    $buttons = if ($WithCancel) { [System.Windows.MessageBoxButton]::YesNoCancel } else { [System.Windows.MessageBoxButton]::YesNo }
    [string][System.Windows.MessageBox]::Show($Context.Window, $Message, 'NCLog Viewer', $buttons,
        [System.Windows.MessageBoxImage]::Question)
}

function Show-NCLogViewerHowTo {
    <#
    .SYNOPSIS
        使い方を表示する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    Show-NCLogViewerMessage -Context $Context -Message (@(
            '【使い方】'
            ''
            '① BIN ファイルを開く'
            '    [開く] (Ctrl+O) で複数選択、またはファイル・フォルダをウィンドウにドラッグ＆ドロップ'
            ''
            '② グラフを右クリックして値を取得'
            '    右クリックした位置のレーザー出力とワイヤ速度が入ります (直接入力も可)'
            ''
            '③ 割合を入力'
            '    Enter で次のファイルに移るので、続けて入力できます'
            ''
            '④ 一括 CSV 出力 (Ctrl+Shift+E)'
            '    ファイル名: レーザー出力W_ワイヤ速度mm-min_割合%.csv'
            '    (ファイル名に "/" は使えないため mm/min は mm-min と書きます)'
            '    一覧で緑色の行が出力できるファイルです'
            ''
            '【その他】'
            '    グラフ: 右クリックで値を取得 / ドラッグで移動 / ホイールで拡大・縮小 / ダブルクリックで全体'
            '    [ツール] メニュー: 16進ダンプ・ファイル情報・レイアウト設定の表示'
        ) -join "`n")
}

function Set-NCLogViewerToolTab {
    <#
    .SYNOPSIS
        [ツール] メニューのタブ (16進ダンプ / ファイル情報) の表示・非表示を切り替える。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を切り替えるだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.Windows.Controls.TabItem]$Tab,
        [Parameter(Mandatory)][bool]$Visible
    )

    $ui = $Context.UI
    $menu = if ([object]::ReferenceEquals($Tab, $ui.HexTab)) { $ui.MenuShowHex } else { $ui.MenuShowInfo }
    $menu.IsChecked = $Visible
    if ($Visible) {
        $Tab.Visibility = [System.Windows.Visibility]::Visible
        $ui.MainTabs.SelectedItem = $Tab
    }
    else {
        if ([object]::ReferenceEquals($ui.MainTabs.SelectedItem, $Tab)) { $ui.MainTabs.SelectedItem = $ui.ChartTab }
        $Tab.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function Set-NCLogViewerLayoutText {
    <#
    .SYNOPSIS
        レイアウトの入力欄に値を表示する (ヘッダーは16進)。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面の入力欄を書き換えるだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Layout
    )

    $Context.UI.HeaderSizeBox.Text = '0x{0:X}' -f $Layout.HeaderSize
    $Context.UI.RecordSizeBox.Text = [string]$Layout.RecordSize
    $Context.UI.Value40OffsetBox.Text = [string]$Layout.Value40Offset
    $Context.UI.Value21OffsetBox.Text = [string]$Layout.Value21Offset
}

function Get-NCLogViewerLayout {
    <#
    .SYNOPSIS
        レイアウトの入力欄を検証して数値で返す。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    Resolve-NCLogViewerLayout -HeaderSize $Context.UI.HeaderSizeBox.Text -RecordSize $Context.UI.RecordSizeBox.Text `
        -Value40Offset $Context.UI.Value40OffsetBox.Text -Value21Offset $Context.UI.Value21OffsetBox.Text
}

function Open-NCLogViewerFileDialog {
    <#
    .SYNOPSIS
        ファイル選択ダイアログで .BIN を選んで開く (複数選択可)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'NCLog ファイルを開く (複数選択できます)'
    $dialog.Filter = 'NCLog ファイル (*.BIN)|*.BIN|すべてのファイル (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $true
    if ($null -ne $Context.Current) {
        $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($Context.Current.Path)
    }
    if ($dialog.ShowDialog($Context.Window) -eq $true) {
        Add-NCLogViewerFile -Context $Context -Path $dialog.FileNames
    }
}

function Add-NCLogViewerFile {
    <#
    .SYNOPSIS
        ファイル (フォルダなら直下の .BIN) を読み込み、現在のレイアウトで解析してファイル一覧に追加する。
    .DESCRIPTION
        開けなかったファイルがあっても残りは開き、最後にまとめて知らせる。
        既に開いているファイルは開き直さずに選択する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        # メモリを使い過ぎないよう、同時に開けるファイル数を制限する (1ファイル最大 16MB)
        [ValidateRange(1, 1000)][int]$MaxFiles = 100
    )

    # 入力欄が不正なら、ファイルを読む前に知らせる
    $layout = Get-NCLogViewerLayout -Context $Context
    $existing = [string[]]@($Context.Files | ForEach-Object { $_.Path })
    $target = Resolve-NCLogViewerOpenTarget -Path $Path -Existing $existing -MaxCount ([Math]::Max(0, $MaxFiles - $Context.Files.Count))

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $target.Messages) { $problems.Add($m) }
    $first = $null

    $Context.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        foreach ($file in $target.Files) {
            try {
                $bytes = Read-NCLogViewFile -LiteralFilePath $file
                $data = New-NCLogViewData -Bytes $bytes -Path $file -LastWriteTime ([System.IO.File]::GetLastWriteTime($file)) @layout
                $entry = New-NCLogViewerFile -Path $file -Data $data
                $Context.Suppress = $true
                try { $Context.Files.Add($entry) } finally { $Context.Suppress = $false }
                if ($null -eq $first) { $first = $entry }
            }
            catch {
                $problems.Add("$([System.IO.Path]::GetFileName($file)): $(Get-NCLogViewerErrorMessage -ErrorRecord $_)")
            }
        }
    }
    finally {
        $Context.Window.Cursor = $null
    }

    if ($null -eq $first -and $target.AlreadyOpen.Count -gt 0) {
        $first = $Context.Files | Where-Object { $_.Path -eq $target.AlreadyOpen[0] } | Select-Object -First 1
    }
    if ($null -ne $first) {
        Select-NCLogViewerFile -Context $Context -File $first
    }
    else {
        Update-NCLogViewerFileList -Context $Context
    }

    $opened = $target.Files.Count - ($problems.Count - $target.Messages.Count)
    $Context.UI.StatusText.Text = "$opened ファイルを開きました。グラフを右クリックして値を取得し、割合を入力してください。"
    if ($problems.Count -gt 0) {
        $shown = @($problems | Select-Object -First 15)
        $more = if ($problems.Count -gt $shown.Count) { "`n… ほか $($problems.Count - $shown.Count) 件" } else { '' }
        Show-NCLogViewerMessage -Context $Context -Icon Warning -Message (
            "開けなかったファイルがあります。`n`n" + ($shown -join "`n") + $more)
    }
}

function Remove-NCLogViewerFile {
    <#
    .SYNOPSIS
        選択中のファイル (All なら全部) をファイル一覧から外す。ファイル自体は削除しない。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面の一覧から外すだけで、ファイルは削除しない')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$All
    )

    $files = $Context.Files
    if ($files.Count -eq 0) { return }

    $next = $null
    $Context.Suppress = $true
    try {
        if ($All) {
            $files.Clear()
        }
        elseif ($null -ne $Context.Current) {
            $index = $files.IndexOf($Context.Current)
            [void]$files.Remove($Context.Current)
            if ($files.Count -gt 0) { $next = $files[[Math]::Min([Math]::Max(0, $index), $files.Count - 1)] }
        }
        else {
            return
        }
    }
    finally {
        $Context.Suppress = $false
    }
    Select-NCLogViewerFile -Context $Context -File $next
}

function Select-NCLogViewerFile {
    <#
    .SYNOPSIS
        ファイル一覧のファイルを選択し、グラフ・レコード・入力欄に表示する。$null なら表示を空にする。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowNull()][object]$File
    )

    $ui = $Context.UI
    $Context.Current = $File
    $Context.Suppress = $true
    try {
        if ($null -eq $File) {
            $ui.FileGrid.SelectedItem = $null
            $ui.LaserBox.Text = ''
            $ui.WireBox.Text = ''
            $ui.RatioBox.Text = ''
            $ui.SelectedFileText.Text = ' '
            $ui.NameGroup.IsEnabled = $false
            Set-NCLogViewerData -Context $Context -Data $null
        }
        else {
            if (-not [object]::ReferenceEquals($ui.FileGrid.SelectedItem, $File)) {
                $ui.FileGrid.SelectedItem = $File
            }
            $ui.FileGrid.ScrollIntoView($File)
            $ui.LaserBox.Text = $File.LaserText
            $ui.WireBox.Text = $File.WireText
            $ui.RatioBox.Text = $File.RatioText
            $ui.SelectedFileText.Text = $File.FileName
            $ui.SelectedFileText.ToolTip = $File.Path
            $ui.NameGroup.IsEnabled = $true
            Set-NCLogViewerData -Context $Context -Data $File.Data
        }
    }
    finally {
        $Context.Suppress = $false
    }
    Update-NCLogViewerPickedText -Context $Context
    Update-NCLogViewerFileList -Context $Context
}

function Select-NCLogViewerNextFile {
    <#
    .SYNOPSIS
        一覧の次のファイルを選択し、割合の入力欄にカーソルを移す (割合の連続入力用)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $files = $Context.Files
    if ($null -eq $Context.Current -or $files.Count -eq 0) { return }
    $index = $files.IndexOf($Context.Current)
    if ($index -ge $files.Count - 1) {
        $Context.UI.StatusText.Text = '最後のファイルです。すべて入力したら [一括 CSV 出力] を押してください。'
        return
    }
    Select-NCLogViewerFile -Context $Context -File $files[$index + 1]
    [void]$Context.UI.RatioBox.Focus()
    $Context.UI.RatioBox.SelectAll()
}

function Update-NCLogViewerFileList {
    <#
    .SYNOPSIS
        出力ファイル名・状態を計算し直し、ファイル一覧と一括出力の表示・ボタンを更新する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $ui = $Context.UI
    $files = @($Context.Files)
    $snapshot = { param($list) ($list | ForEach-Object { "$($_.OutputName)|$($_.Status)|$($_.IsReady)" }) -join "`n" }
    $before = & $snapshot $files
    Update-NCLogViewerFileState -File $files -OutputDirectory $ui.OutputDirBox.Text

    # NCLogViewerFile は変更通知を持たないため、表示内容が変わったときだけ一覧を描き直す
    # (選択を変えただけで描き直すと、矢印キーでの行移動がリセットされるため)
    if ((& $snapshot $files) -cne $before) {
        $Context.Suppress = $true
        try {
            $ui.FileGrid.Items.Refresh()
            if ($null -ne $Context.Current -and -not [object]::ReferenceEquals($ui.FileGrid.SelectedItem, $Context.Current)) {
                $ui.FileGrid.SelectedItem = $Context.Current
            }
        }
        finally {
            $Context.Suppress = $false
        }
    }

    $ready = @($files | Where-Object { $_.IsReady }).Count
    $ui.BatchSummaryText.Text = "出力できるファイル: $ready / $($files.Count) 件"
    $ui.FileCountText.Text = "$($files.Count) ファイル"
    $ui.BatchExportButton.IsEnabled = $ready -gt 0
    $ui.ToolbarBatchExportButton.IsEnabled = $ready -gt 0
    $ui.MenuBatchExport.IsEnabled = $ready -gt 0
    $ui.RemoveButton.IsEnabled = $null -ne $Context.Current
    $ui.MenuRemove.IsEnabled = $null -ne $Context.Current
    $ui.MenuRemoveAll.IsEnabled = $files.Count -gt 0
    $ui.ApplyLayoutButton.IsEnabled = $files.Count -gt 0

    $current = $Context.Current
    if ($null -eq $current) {
        $ui.OutputNameText.Text = '(ファイルを選択してください)'
        $ui.OutputNameText.Foreground = [System.Windows.Media.Brushes]::Gray
    }
    elseif ($current.OutputName) {
        $ui.OutputNameText.Text = $current.OutputName
        $ui.OutputNameText.Foreground = if ($current.IsReady) { [System.Windows.Media.Brushes]::Black } else { [System.Windows.Media.Brushes]::Firebrick }
        $ui.OutputNameText.ToolTip = "$($current.OutputPath)`n$($current.Status)"
    }
    else {
        $ui.OutputNameText.Text = "($($current.Status))"
        $ui.OutputNameText.Foreground = [System.Windows.Media.Brushes]::Gray
        $ui.OutputNameText.ToolTip = $null
    }
}

function Update-NCLogViewerPickedText {
    <#
    .SYNOPSIS
        グラフから取得したレコードの表示を更新する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $current = $Context.Current
    $Context.UI.PickedText.Text = if ($null -ne $current -and $current.PickedRecord -ge 0 -and
        $current.PickedRecord -lt $current.Data.RecordCount) {
        [string]::Format([System.Globalization.CultureInfo]::InvariantCulture,
            'グラフの No.{0} から取得しました (ADD_40_0 = {1:0.######} W / ADD_21_0 = {2:0.######} mm/min)。緑の線が取得位置です。',
            $current.PickedRecord, $current.Data.Value40[$current.PickedRecord], $current.Data.Value21[$current.PickedRecord])
    }
    else {
        'グラフを右クリックすると、その位置のレーザー出力とワイヤ速度が入ります。'
    }
}

function Set-NCLogViewerPickedRecord {
    <#
    .SYNOPSIS
        グラフで右クリックしたレコードのレーザー出力・ワイヤ速度を、選択中ファイルの出力ファイル名の値にする。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面の入力値を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][int]$Index
    )

    $current = $Context.Current
    if ($null -eq $current) { return }
    $data = $current.Data
    $v40 = $data.Value40[$Index]
    $v21 = $data.Value21[$Index]
    if (-not ([float]::IsFinite($v40) -and [float]::IsFinite($v21))) {
        throw [System.InvalidOperationException]::new(
            "No.$Index は無効レコード (NaN / Infinity) のため値を取得できません。別の位置を右クリックしてください。")
    }

    $current.LaserText = Format-NCLogFileNameValue -Value $v40
    $current.WireText = Format-NCLogFileNameValue -Value $v21
    $current.PickedRecord = $Index

    $Context.Suppress = $true
    try {
        $Context.UI.LaserBox.Text = $current.LaserText
        $Context.UI.WireBox.Text = $current.WireText
    }
    finally {
        $Context.Suppress = $false
    }
    Update-NCLogViewerPickedText -Context $Context
    Update-NCLogViewerFileList -Context $Context
    Update-NCLogViewerChart -Context $Context
    $Context.UI.StatusText.Text = "No.$Index の値を取得しました: レーザー出力 $($current.LaserText) W / ワイヤ速度 $($current.WireText) mm/min"

    # 割合が未入力なら、続けて入力できるようにする
    if ([string]::IsNullOrWhiteSpace($current.RatioText)) {
        [void]$Context.UI.RatioBox.Focus()
    }
}

function Update-NCLogViewerLayout {
    <#
    .SYNOPSIS
        開いているすべてのファイルを、入力欄のレイアウトで解析し直す (ファイルは読み直さない)。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    if ($Context.Files.Count -eq 0) { return }
    $layout = Get-NCLogViewerLayout -Context $Context
    $Context.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        foreach ($f in $Context.Files) {
            $f.Data = New-NCLogViewData -Bytes $f.Data.Bytes -Path $f.Path -LastWriteTime $f.Data.LastWriteTime @layout
            if ($f.PickedRecord -ge $f.Data.RecordCount) { $f.PickedRecord = -1 }
        }
    }
    finally {
        $Context.Window.Cursor = $null
    }
    Select-NCLogViewerFile -Context $Context -File $Context.Current
}

function Set-NCLogViewerData {
    <#
    .SYNOPSIS
        解析結果を全タブに反映する。$null なら表示を空にする。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowNull()][psobject]$Data
    )

    $ui = $Context.UI
    $Context.Data = $Data

    if ($null -eq $Data) {
        $Context.RecordList = $null
        $Context.HexList = $null
        foreach ($grid in $ui.RecordGrid, $ui.HexGrid, $ui.InspectorGrid, $ui.FileInfoGrid, $ui.StatisticsGrid, $ui.HeaderGrid) {
            $grid.ItemsSource = $null
        }
        $ui.MenuExport.IsEnabled = $false
        $ui.ChartEmptyText.Visibility = [System.Windows.Visibility]::Visible
        $Context.Window.Title = 'NCLog Viewer'
        $ui.StatusText.Text = 'ファイルを開くか、ウィンドウにドラッグ＆ドロップしてください。'
        $ui.SelectionText.Text = ''
        $ui.HoverText.Text = ' '
        $ui.RangeStartBox.Text = ''
        $ui.RangeEndBox.Text = ''
        $Context.ViewStart = 0
        $Context.ViewEnd = 0
        Update-NCLogViewerChart -Context $Context
        return
    }

    $Context.RecordList = New-NCLogRecordRowList -Value40 $Data.Value40 -Value21 $Data.Value21 `
        -HeaderSize $Data.HeaderSize -RecordSize $Data.RecordSize
    $Context.HexList = New-NCLogHexRowList -Bytes $Data.Bytes -HeaderSize $Data.HeaderSize `
        -RecordSize $Data.RecordSize -RecordCount $Data.RecordCount

    $ui.RecordGrid.ItemsSource = $Context.RecordList
    $ui.HexGrid.ItemsSource = $Context.HexList

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $ui.FileInfoGrid.ItemsSource = @(
        [pscustomobject]@{ Name = 'パス'; Value = $Data.Path }
        [pscustomobject]@{ Name = 'サイズ'; Value = [string]::Format($ic, '{0:N0} byte', $Data.Length) }
        [pscustomobject]@{ Name = '更新日時'; Value = $Data.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
        [pscustomobject]@{ Name = 'ヘッダーサイズ'; Value = [string]::Format($ic, '{0} byte (0x{0:X})', $Data.HeaderSize) }
        [pscustomobject]@{ Name = 'レコードサイズ'; Value = [string]::Format($ic, '{0} byte', $Data.RecordSize) }
        [pscustomobject]@{ Name = 'ADD_40_0 の位置'; Value = [string]::Format($ic, '+{0} (float32)', $Data.Value40Offset) }
        [pscustomobject]@{ Name = 'ADD_21_0 の位置'; Value = [string]::Format($ic, '+{0} (float32)', $Data.Value21Offset) }
        [pscustomobject]@{ Name = 'レコード数'; Value = [string]::Format($ic, '{0:N0}', $Data.RecordCount) }
        [pscustomobject]@{ Name = '無効レコード'; Value = [string]::Format($ic, '{0:N0} (NaN / Infinity を含む)', $Data.InvalidCount) }
        [pscustomobject]@{ Name = '末尾の端数'; Value = [string]::Format($ic, '{0} byte{1}', $Data.TrailingBytes,
                $(if ($Data.TrailingBytes -ne 0) { ' ※レイアウトが実データと合っていない可能性があります' } else { '' })) }
    )
    $ui.StatisticsGrid.ItemsSource = @($Data.Statistics)
    $ui.HeaderGrid.ItemsSource = @($Data.HeaderWords)

    $ui.MenuExport.IsEnabled = $Data.RecordCount -gt 0
    $ui.ChartEmptyText.Visibility = [System.Windows.Visibility]::Collapsed

    $Context.Window.Title = "NCLog Viewer - $($Data.FileName)"
    $ui.StatusText.Text = [string]::Format($ic, '{0}  |  {1:N0} byte  |  {2:N0} レコード (無効 {3:N0})  |  端数 {4} byte',
        $Data.FileName, $Data.Length, $Data.RecordCount, $Data.InvalidCount, $Data.TrailingBytes)
    $ui.SelectionText.Text = ''

    Update-NCLogViewerInspector -Context $Context -Offset $(if ($Data.Length -gt $Data.HeaderSize) { $Data.HeaderSize } else { 0 })
    Set-NCLogViewerChartRange -Context $Context -Start 0 -End ([Math]::Max(0, $Data.RecordCount - 1)) -Force
}

function Update-NCLogViewerInspector {
    <#
    .SYNOPSIS
        16進ダンプの選択位置の数値解釈を表示する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][long]$Offset
    )

    $data = $Context.Data
    $Context.UI.OffsetBox.Text = '0x{0:X}' -f $Offset
    $Context.UI.InspectorGrid.ItemsSource = @(Get-NCLogByteInterpretation -Bytes $data.Bytes -Offset $Offset)

    $where = if ($Offset -lt $data.HeaderSize) {
        'ヘッダー'
    }
    elseif ($Offset -lt $data.HeaderSize + [long]$data.RecordCount * $data.RecordSize) {
        $relative = $Offset - $data.HeaderSize
        'レコード {0} の +{1}' -f [Math]::Floor($relative / $data.RecordSize), ($relative % $data.RecordSize)
    }
    else {
        '末尾の端数'
    }
    $Context.UI.SelectionText.Text = '0x{0:X8} ({0})  {1}' -f $Offset, $where
}

function Select-NCLogViewerHexOffset {
    <#
    .SYNOPSIS
        16進ダンプで指定オフセットのセルを選択し、表示位置まで移動する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][long]$Offset
    )

    $length = $Context.Data.Length
    if ($Offset -lt 0 -or $Offset -ge $length) {
        throw [System.ArgumentOutOfRangeException]::new('Offset', $Offset,
            "オフセットは 0 ～ 0x{0:X} ({0}) の範囲で指定してください。" -f ($length - 1))
    }

    $grid = $Context.UI.HexGrid
    $item = $Context.HexList.get_Item([int][Math]::Floor($Offset / 16))
    $column = $grid.Columns[2 + [int]($Offset % 16)]
    $grid.ScrollIntoView($item, $column)
    $cell = [System.Windows.Controls.DataGridCellInfo]::new($item, $column)
    $grid.SelectedCells.Clear()
    $grid.SelectedCells.Add($cell)
    $grid.CurrentCell = $cell
    [void]$grid.Focus()
    Update-NCLogViewerInspector -Context $Context -Offset $Offset
}

function Set-NCLogViewerChartRange {
    <#
    .SYNOPSIS
        グラフの表示範囲 (レコード番号) を設定して再描画する。範囲はデータ内に収める。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$End,
        # 範囲が変わらなくても描き直す (ファイルを開き直したとき)
        [switch]$Force
    )

    if ($null -eq $Context.Data) { return }
    $last = [Math]::Max(0, $Context.Data.RecordCount - 1)
    $count = [Math]::Min([Math]::Max(1, $End - $Start), [Math]::Max(1, $last))
    $first = [int][Math]::Max(0, [Math]::Min($Start, $last - $count))
    $final = [int][Math]::Min($last, $first + $count)
    # ドラッグで端に達した後などは範囲が変わらないので、重い再描画を省く
    if (-not $Force -and $first -eq $Context.ViewStart -and $final -eq $Context.ViewEnd) { return }
    $Context.ViewStart = $first
    $Context.ViewEnd = $final
    $Context.UI.RangeStartBox.Text = [string]$Context.ViewStart
    $Context.UI.RangeEndBox.Text = [string]$Context.ViewEnd
    Update-NCLogViewerChart -Context $Context
}

function Update-NCLogViewerChart {
    <#
    .SYNOPSIS
        2つのグラフ (ADD_40_0 / ADD_21_0) を現在の表示範囲で描き直す。値を取得した位置には緑の線を引く。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $ui = $Context.UI
    $data = $Context.Data
    $picked = if ($null -ne $Context.Current -and $null -ne $data) { $Context.Current.PickedRecord } else { -1 }
    $charts = @(
        @{ Canvas = $ui.Chart40Canvas; Max = $ui.Chart40MaxText; Min = $ui.Chart40MinText; Brush = 'Value40Brush'; CursorKey = 'Cursor40'
            Values = $(if ($data) { $data.Plot40 } else { $null })
        }
        @{ Canvas = $ui.Chart21Canvas; Max = $ui.Chart21MaxText; Min = $ui.Chart21MinText; Brush = 'Value21Brush'; CursorKey = 'Cursor21'
            Values = $(if ($data) { $data.Plot21 } else { $null })
        }
    )

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($chart in $charts) {
        $canvas = $chart.Canvas
        $canvas.Children.Clear()
        $Context[$chart.CursorKey] = $null
        $chart.Max.Text = ''
        $chart.Min.Text = ''
        $width = $canvas.ActualWidth
        $height = $canvas.ActualHeight
        if ($null -eq $chart.Values -or $chart.Values.Length -eq 0 -or $width -lt 2 -or $height -lt 2) { continue }

        # 補助線 (上下端と 1/4 ごと)
        foreach ($fraction in 0.25, 0.5, 0.75) {
            $grid = [System.Windows.Shapes.Line]@{
                X1 = 0; X2 = $width; Y1 = $height * $fraction; Y2 = $height * $fraction
                Stroke = [System.Windows.Media.Brushes]::Gainsboro; StrokeThickness = 1
            }
            [void]$canvas.Children.Add($grid)
        }

        # 値を取得した位置 (緑の実線)
        if ($picked -ge 0) {
            $px = Get-NCLogChartX -Index $picked -Width $width -Start $Context.ViewStart -End $Context.ViewEnd
            if ($null -ne $px) {
                $pickLine = [System.Windows.Shapes.Line]@{
                    X1 = $px; X2 = $px; Y1 = 0; Y2 = $height
                    Stroke = $Context.Window.FindResource('PickBrush'); StrokeThickness = 2; IsHitTestVisible = $false
                }
                [void]$canvas.Children.Add($pickLine)
            }
        }

        $geometry = Get-NCLogPlotGeometry -Value $chart.Values -Start $Context.ViewStart -End $Context.ViewEnd `
            -Width $width -Height ($height - 8) -Margin 0.05
        if ($geometry.PointCount -gt 0) {
            $line = [System.Windows.Shapes.Polyline]::new()
            $line.Points = [System.Windows.Media.PointCollection]::Parse($geometry.Points)
            $line.Stroke = $Context.Window.FindResource($chart.Brush)
            $line.StrokeThickness = 1.2
            $line.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
            $line.IsHitTestVisible = $false
            # 上下 4px の余白
            [System.Windows.Controls.Canvas]::SetTop($line, 4)
            [void]$canvas.Children.Add($line)
            $chart.Max.Text = $geometry.Maximum.ToString('G6', $ic)
            $chart.Min.Text = $geometry.Minimum.ToString('G6', $ic)
        }

        # マウス位置の縦線 (MouseMove で位置を更新)
        $cursorLine = [System.Windows.Shapes.Line]@{
            X1 = 0; X2 = 0; Y1 = 0; Y2 = $height
            Stroke = [System.Windows.Media.Brushes]::DimGray; StrokeThickness = 1
            Visibility = [System.Windows.Visibility]::Hidden; IsHitTestVisible = $false
        }
        $cursorLine.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('3 3')
        [void]$canvas.Children.Add($cursorLine)
        $Context[$chart.CursorKey] = $cursorLine
    }

    if ($null -ne $data -and $data.RecordCount -gt 0) {
        $ui.AxisStartText.Text = "No.$($Context.ViewStart)"
        $ui.AxisEndText.Text = "No.$($Context.ViewEnd)"
    }
    else {
        $ui.AxisStartText.Text = ''
        $ui.AxisEndText.Text = ''
    }
}

function Update-NCLogViewerChartCursor {
    <#
    .SYNOPSIS
        マウス位置のレコードの値を表示し、両グラフに縦線を引く。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][double]$X,
        [Parameter(Mandatory)][double]$Width
    )

    $data = $Context.Data
    $index = Get-NCLogChartIndex -X $X -Width $Width -Start $Context.ViewStart -End $Context.ViewEnd -RecordCount $data.RecordCount

    foreach ($line in $Context.Cursor40, $Context.Cursor21) {
        if ($null -eq $line) { continue }
        $line.X1 = $X
        $line.X2 = $X
        $line.Visibility = [System.Windows.Visibility]::Visible
    }

    $Context.UI.HoverText.Text = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture,
        'No.{0}   ADD_40_0 = {1:0.######} W   ADD_21_0 = {2:0.######} mm/min{3}',
        $index, $data.Value40[$index], $data.Value21[$index],
        $(if ([float]::IsFinite($data.Value40[$index]) -and [float]::IsFinite($data.Value21[$index])) { '   (右クリックで取得)' } else { '   (無効レコード)' }))
}

function Select-NCLogViewerOutputDirectory {
    <#
    .SYNOPSIS
        一括 CSV 出力の出力先フォルダを選ぶ。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $box = $Context.UI.OutputDirBox
    $initial = if (-not [string]::IsNullOrWhiteSpace($box.Text) -and [System.IO.Directory]::Exists($box.Text.Trim())) {
        $box.Text.Trim()
    }
    elseif ($null -ne $Context.Current) {
        [System.IO.Path]::GetDirectoryName($Context.Current.Path)
    }
    else { '' }

    # .NET 8 (PowerShell 7.4 以降) は WPF のフォルダ選択ダイアログがある。それより前は Windows フォーム版を使う
    $folderDialogType = 'Microsoft.Win32.OpenFolderDialog' -as [type]
    if ($null -ne $folderDialogType) {
        $dialog = $folderDialogType::new()
        $dialog.Title = 'CSV の出力先フォルダを選択'
        if ($initial) { $dialog.InitialDirectory = $initial }
        if ($dialog.ShowDialog($Context.Window) -eq $true) { $box.Text = $dialog.FolderName }
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = 'CSV の出力先フォルダを選択'
        $dialog.UseDescriptionForTitle = $true
        if ($initial) { $dialog.SelectedPath = $initial }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $box.Text = $dialog.SelectedPath }
    }
    finally {
        $dialog.Dispose()
    }
}

function Export-NCLogViewerCsv {
    <#
    .SYNOPSIS
        選択中のファイルを、表示中のレイアウトで CSV に出力する (Export-NCLogValue を使用)。
        ファイル名の初期値は出力ファイル名 (入力済みの場合)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $data = $Context.Data
    $current = $Context.Current
    if ($null -eq $data -or $null -eq $current) { return }
    $valid = $data.RecordCount - $data.InvalidCount
    if ($valid -le 0) {
        Show-NCLogViewerMessage -Context $Context -Icon Warning -Message '出力できる有効なレコードがありません。'
        return
    }

    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'CSV に出力'
    $dialog.Filter = 'CSV ファイル (*.csv)|*.csv'
    $dialog.DefaultExt = '.csv'
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true   # 上書きはダイアログで確認済みとして -Force で出力する
    if ($current.OutputPath) {
        $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($current.OutputPath)
        $dialog.FileName = $current.OutputName
    }
    else {
        $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($data.Path)
        $dialog.FileName = [System.IO.Path]::GetFileNameWithoutExtension($data.Path) + '.csv'
    }
    if ($dialog.ShowDialog($Context.Window) -ne $true) { return }

    # 解析結果と CSV が一致するよう、表示中のレイアウトを使う (入力欄を編集中でも再解析前の値)
    $Context.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $exportParams = @{
            LiteralPath   = $data.Path
            Format        = 'CSV'
            OutputPath    = $dialog.FileName
            Force         = $true
            HeaderSize    = $data.HeaderSize
            RecordSize    = $data.RecordSize
            Value40Offset = $data.Value40Offset
            Value21Offset = $data.Value21Offset
            ErrorAction   = 'Stop'
            WarningAction = 'SilentlyContinue'
        }
        # Export-NCLogValue は完了メッセージを Write-Host で出すため、情報ストリームごと捨てる
        Export-NCLogValue @exportParams 6>$null
    }
    finally {
        $Context.Window.Cursor = $null
    }

    $note = if ([System.IO.File]::GetLastWriteTime($data.Path) -ne $data.LastWriteTime) {
        "`n`n※ 開いた後にファイルが更新されています。CSV は現在のファイル内容から作成しました。"
    }
    else { '' }
    Show-NCLogViewerMessage -Context $Context -Message ("CSV に出力しました ($valid 件)。`n$($dialog.FileName)$note")
}

function Export-NCLogViewerBatchCsv {
    <#
    .SYNOPSIS
        出力できるファイル (一覧で緑の行) を、それぞれの出力ファイル名で CSV に一括出力する。
    .DESCRIPTION
        - 未入力・重複などで出力できないファイルがあれば、出力できる分だけ出力するか確認する
        - 出力先フォルダがなければ作成するか確認する
        - 既に同名の CSV があれば、上書き / スキップ / 中止 を確認する
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $files = @($Context.Files)
    if ($files.Count -eq 0) {
        Show-NCLogViewerMessage -Context $Context -Icon Warning -Message 'BIN ファイルを開いてください。'
        return
    }

    # 出力先フォルダ (空欄なら各 BIN と同じフォルダ)
    $directory = $Context.UI.OutputDirBox.Text.Trim()
    if ($directory) {
        if (-not [System.IO.Path]::IsPathRooted($directory)) {
            throw [System.ArgumentException]::new("出力先フォルダは C:\... のような絶対パスで指定してください: $directory")
        }
        if (-not [System.IO.Directory]::Exists($directory)) {
            $answer = Show-NCLogViewerQuestion -Context $Context -Message "出力先フォルダがありません。作成しますか?`n`n$directory"
            if ($answer -ne 'Yes') { return }
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
    }

    Update-NCLogViewerFileList -Context $Context
    $ready = @($files | Where-Object { $_.IsReady })
    $notReady = @($files | Where-Object { -not $_.IsReady })
    $describe = {
        param($list)
        $lines = @($list | Select-Object -First 10 | ForEach-Object { "  $($_.FileName): $($_.Status)" })
        if ($list.Count -gt $lines.Count) { $lines += "  … ほか $($list.Count - $lines.Count) 件" }
        $lines -join "`n"
    }

    if ($ready.Count -eq 0) {
        Show-NCLogViewerMessage -Context $Context -Icon Warning -Message (
            "出力できるファイルがありません。レーザー出力・ワイヤ速度・割合を入力してください。`n`n" + (& $describe $notReady))
        return
    }
    if ($notReady.Count -gt 0) {
        $answer = Show-NCLogViewerQuestion -Context $Context -Message (
            "次の $($notReady.Count) 件は出力できません:`n`n" + (& $describe $notReady) +
            "`n`n出力できる $($ready.Count) 件だけ出力しますか?")
        if ($answer -ne 'Yes') { return }
    }

    $existing = @($ready | Where-Object { [System.IO.File]::Exists($_.OutputPath) })
    $existingAction = 'Skip'
    if ($existing.Count -gt 0) {
        $names = @($existing | Select-Object -First 10 | ForEach-Object { "  $($_.OutputName)" })
        $answer = Show-NCLogViewerQuestion -Context $Context -WithCancel -Message (
            "$($existing.Count) 件の CSV が既にあります:`n`n" + ($names -join "`n") +
            "`n`nはい: 上書きする`nいいえ: 既にあるファイルは出力しない`nキャンセル: 中止する")
        if ($answer -eq 'Cancel') { return }
        if ($answer -eq 'Yes') { $existingAction = 'Overwrite' }
    }

    # 表示中のレイアウト (各ファイルの解析に使ったもの) で出力する
    $items = foreach ($f in $ready) {
        [pscustomobject]@{
            SourcePath    = $f.Path
            OutputPath    = $f.OutputPath
            HeaderSize    = $f.Data.HeaderSize
            RecordSize    = $f.Data.RecordSize
            Value40Offset = $f.Data.Value40Offset
            Value21Offset = $f.Data.Value21Offset
            ValidCount    = $f.Data.RecordCount - $f.Data.InvalidCount
        }
    }

    $Context.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $results = @(Invoke-NCLogBatchCsvExport -Item @($items) -ExistingAction $existingAction -Confirm:$false)
    }
    finally {
        $Context.Window.Cursor = $null
    }

    $exported = @($results | Where-Object Result -eq 'Exported')
    $skipped = @($results | Where-Object Result -eq 'Skipped')
    $failed = @($results | Where-Object Result -eq 'Failed')
    $folders = @($exported | ForEach-Object { [System.IO.Path]::GetDirectoryName($_.OutputPath) } | Sort-Object -Unique)

    $message = [System.Text.StringBuilder]::new()
    [void]$message.AppendLine("CSV を $($exported.Count) 件出力しました。")
    if ($folders.Count -eq 1) { [void]$message.AppendLine("出力先: $($folders[0])") }
    if ($skipped.Count -gt 0) { [void]$message.AppendLine("既にあるため出力しなかった: $($skipped.Count) 件") }
    if ($failed.Count -gt 0) {
        [void]$message.AppendLine("`n失敗: $($failed.Count) 件")
        foreach ($r in @($failed | Select-Object -First 10)) {
            [void]$message.AppendLine("  $([System.IO.Path]::GetFileName($r.SourcePath)): $($r.Message)")
        }
    }
    $Context.UI.StatusText.Text = "一括 CSV 出力: 出力 $($exported.Count) 件 / スキップ $($skipped.Count) 件 / 失敗 $($failed.Count) 件"
    Show-NCLogViewerMessage -Context $Context -Icon $(if ($failed.Count -gt 0) { 'Warning' } else { 'Information' }) -Message $message.ToString().TrimEnd()
}
