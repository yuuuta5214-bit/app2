<#
    NCLog Viewer の画面処理 (WPF)。Windows 専用。

    Show-NCLogViewer から呼ばれる内部関数群。画面に依存しない処理 (解析・統計・グラフ座標・
    16進表示の行生成) は Private フォルダにあり、Pester で単体テストしている。
    このファイルは WPF の部品を操作するだけに留める。

    状態は $ctx (hashtable) に集約し、各関数へ -Context で渡す:
        $ctx.Window / $ctx.UI.<x:Name>       画面部品
        $ctx.Bytes / $ctx.Data               読み込んだバイト列と解析結果 (New-NCLogViewData)
        $ctx.HexList / $ctx.RecordList       DataGrid に渡した遅延生成リスト
        $ctx.ViewStart / $ctx.ViewEnd        グラフの表示範囲 (レコード番号)
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
        [AllowNull()][string]$LiteralFilePath,
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
            'MenuOpen', 'MenuExport', 'MenuExit', 'MenuAbout', 'OpenButton', 'ExportButton',
            'HeaderSizeBox', 'RecordSizeBox', 'Value40OffsetBox', 'Value21OffsetBox', 'ApplyLayoutButton', 'ResetLayoutButton',
            'StatusText', 'SelectionText', 'MainTabs', 'RecordTab', 'HexTab', 'ChartTab', 'InfoTab',
            'RecordJumpBox', 'RecordJumpButton', 'RecordGrid', 'HexGrid', 'OffsetBox', 'OffsetJumpButton', 'InspectorGrid',
            'RangeStartBox', 'RangeEndBox', 'RangeApplyButton', 'RangeResetButton', 'HoverText', 'AxisStartText', 'AxisEndText',
            'Chart40Canvas', 'Chart40MaxText', 'Chart40MinText', 'Chart21Canvas', 'Chart21MaxText', 'Chart21MinText',
            'FileInfoGrid', 'StatisticsGrid', 'HeaderGrid'
        )) {
        $element = $window.FindName($name)
        if ($null -eq $element) { throw "XAML に要素 '$name' がありません: $xamlPath" }
        $ui[$name] = $element
    }

    $ctx = @{
        Window        = $window
        UI            = $ui
        Bytes         = $null
        Data          = $null
        HexList       = $null
        RecordList    = $null
        ViewStart     = 0
        ViewEnd       = 0
        Drag          = $null
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

    # --- イベント登録 -------------------------------------------------------------
    # ハンドラーはこの関数の中から ShowDialog で呼ばれるため、$ctx をそのまま参照できる。
    # 例外が WPF のメッセージループまで届くとプロセスが落ちるので、必ず Invoke-NCLogViewerAction を通す。
    $openHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Open-NCLogViewerFileDialog -Context $ctx } }
    $exportHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Export-NCLogViewerCsv -Context $ctx } }
    $applyHandler = { Invoke-NCLogViewerAction -Context $ctx -Action { Update-NCLogViewerLayout -Context $ctx } }

    $ui.MenuOpen.Add_Click($openHandler)
    $ui.OpenButton.Add_Click($openHandler)
    $ui.MenuExport.Add_Click($exportHandler)
    $ui.ExportButton.Add_Click($exportHandler)
    $ui.ApplyLayoutButton.Add_Click($applyHandler)
    $ui.MenuExit.Add_Click({ $ctx.Window.Close() })
    $ui.MenuAbout.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                $module = Get-Module -Name NCLogTools
                $version = if ($module) { $module.Version } else { '?' }
                Show-NCLogViewerMessage -Context $ctx -Icon Information -Message (
                    "NCLog Viewer (NCLogTools $version)`n`nワイヤレーザー3Dプリンターの NCLog バイナリ (.BIN) を閲覧します。`n" +
                    "ファイルは読み取り専用で開き、変更しません。")
            }
        })
    $ui.ResetLayoutButton.Add_Click({
            Invoke-NCLogViewerAction -Context $ctx -Action {
                Set-NCLogViewerLayoutText -Context $ctx -Layout $ctx.DefaultLayout
                if ($null -ne $ctx.Bytes) { Update-NCLogViewerLayout -Context $ctx }
            }
        })
    foreach ($box in $ui.HeaderSizeBox, $ui.RecordSizeBox, $ui.Value40OffsetBox, $ui.Value21OffsetBox) {
        $box.Add_KeyDown({
                param($s, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $null -ne $ctx.Bytes) {
                    $e.Handled = $true
                    Invoke-NCLogViewerAction -Context $ctx -Action { Update-NCLogViewerLayout -Context $ctx }
                }
            })
    }

    # ショートカットキー
    $window.Add_PreviewKeyDown({
            param($s, $e)
            if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::Control) { return }
            if ($e.Key -eq [System.Windows.Input.Key]::O) {
                $e.Handled = $true
                Invoke-NCLogViewerAction -Context $ctx -Action { Open-NCLogViewerFileDialog -Context $ctx }
            }
            elseif ($e.Key -eq [System.Windows.Input.Key]::E -and $null -ne $ctx.Data) {
                $e.Handled = $true
                Invoke-NCLogViewerAction -Context $ctx -Action { Export-NCLogViewerCsv -Context $ctx }
            }
        })

    # ドラッグ＆ドロップ (ファイル1つ)
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
                if ($dropped.Count -eq 0) { return }
                if ($dropped.Count -gt 1) {
                    Show-NCLogViewerMessage -Context $ctx -Icon Warning -Message '一度に開けるのは1ファイルです。先頭のファイルを開きます。'
                }
                if ([System.IO.Directory]::Exists($dropped[0])) {
                    throw [System.IO.IOException]::new("フォルダは開けません。.BIN ファイルをドロップしてください: $($dropped[0])")
                }
                Open-NCLogViewerFile -Context $ctx -LiteralFilePath $dropped[0]
            }
        })

    # ① レコード表
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
                $ctx.UI.MainTabs.SelectedItem = $ctx.UI.HexTab
                # 初めて表示するタブは DataGrid の生成前でスクロールできないため、描画後に移動する
                [void]$ctx.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [Action]{
                        Invoke-NCLogViewerAction -Context $ctx -Action {
                            Select-NCLogViewerHexOffset -Context $ctx -Offset $ctx.PendingOffset
                        }
                    })
            }
        })

    # ② 16進ダンプ
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

    # ③ グラフ
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
        $canvas.Add_MouseMove({
                param($s, $e)
                Invoke-NCLogViewerAction -Context $ctx -Action {
                    if ($null -eq $ctx.Data -or $ctx.Data.RecordCount -eq 0) { return }
                    $x = $e.GetPosition($s).X
                    $width = [Math]::Max(1.0, $s.ActualWidth)
                    if ($null -ne $ctx.Drag -and $e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
                        $shift = [Math]::Round(($ctx.Drag.X - $x) / $width * ($ctx.Drag.End - $ctx.Drag.Start))
                        Set-NCLogViewerChartRange -Context $ctx -Start ($ctx.Drag.Start + $shift) -End ($ctx.Drag.End + $shift)
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
                if ($LiteralFilePath) { Open-NCLogViewerFile -Context $ctx -LiteralFilePath $LiteralFilePath }
            }
        })

    [void]$window.ShowDialog()
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
        $ex = $_.Exception
        # .NET メソッド呼び出しの例外は MethodInvocationException に包まれるので、中身のメッセージを出す
        while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) {
            $ex = $ex.InnerException
        }
        Write-Verbose ($_ | Out-String)
        Show-NCLogViewerMessage -Context $Context -Icon Warning -Message $ex.Message
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
        ファイル選択ダイアログで .BIN を選んで開く。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'NCLog ファイルを開く'
    $dialog.Filter = 'NCLog ファイル (*.BIN)|*.BIN|すべてのファイル (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($null -ne $Context.Data) {
        $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($Context.Data.Path)
    }
    if ($dialog.ShowDialog($Context.Window) -eq $true) {
        Open-NCLogViewerFile -Context $Context -LiteralFilePath $dialog.FileName
    }
}

function Open-NCLogViewerFile {
    <#
    .SYNOPSIS
        ファイルを読み込み、現在のレイアウトで解析して表示する。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$LiteralFilePath
    )

    # 入力欄が不正なら、ファイルを読む前に知らせる
    $layout = Get-NCLogViewerLayout -Context $Context
    $fullPath = [System.IO.Path]::GetFullPath($LiteralFilePath)
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw [System.IO.FileNotFoundException]::new("ファイルが見つかりません: $fullPath", $fullPath)
    }

    $Context.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $bytes = Read-NCLogViewFile -LiteralFilePath $fullPath
        $data = New-NCLogViewData -Bytes $bytes -Path $fullPath -LastWriteTime ([System.IO.File]::GetLastWriteTime($fullPath)) @layout
        $Context.Bytes = $bytes
        Set-NCLogViewerData -Context $Context -Data $data
    }
    finally {
        $Context.Window.Cursor = $null
    }
}

function Update-NCLogViewerLayout {
    <#
    .SYNOPSIS
        読み込み済みのバイト列を、入力欄のレイアウトで解析し直す (ファイルは読み直さない)。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    if ($null -eq $Context.Bytes) { return }
    $layout = Get-NCLogViewerLayout -Context $Context
    $data = New-NCLogViewData -Bytes $Context.Bytes -Path $Context.Data.Path -LastWriteTime $Context.Data.LastWriteTime @layout
    Set-NCLogViewerData -Context $Context -Data $data
}

function Set-NCLogViewerData {
    <#
    .SYNOPSIS
        解析結果を全タブに反映する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][psobject]$Data
    )

    $ui = $Context.UI
    $Context.Data = $Data
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

    $hasRecords = $Data.RecordCount -gt 0
    $ui.ExportButton.IsEnabled = $hasRecords
    $ui.MenuExport.IsEnabled = $hasRecords
    $ui.ApplyLayoutButton.IsEnabled = $true

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
        2つのグラフ (ADD_40_0 / ADD_21_0) を現在の表示範囲で描き直す。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = '画面表示を更新するだけ')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $ui = $Context.UI
    $data = $Context.Data
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

        $geometry = Get-NCLogPlotGeometry -Value $chart.Values -Start $Context.ViewStart -End $Context.ViewEnd `
            -Width $width -Height ($height - 8) -Margin 0.05
        if ($geometry.PointCount -gt 0) {
            $line = [System.Windows.Shapes.Polyline]::new()
            $line.Points = [System.Windows.Media.PointCollection]::Parse($geometry.Points)
            $line.Stroke = $Context.Window.FindResource($chart.Brush)
            $line.StrokeThickness = 1.2
            $line.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
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
    $count = $Context.ViewEnd - $Context.ViewStart
    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, $X / $Width))
    $index = [int][Math]::Round($Context.ViewStart + $ratio * $count)
    $index = [Math]::Min([Math]::Max(0, $index), $data.RecordCount - 1)

    foreach ($line in $Context.Cursor40, $Context.Cursor21) {
        if ($null -eq $line) { continue }
        $line.X1 = $X
        $line.X2 = $X
        $line.Visibility = [System.Windows.Visibility]::Visible
    }

    $Context.UI.HoverText.Text = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture,
        'No.{0}   ADD_40_0 = {1:0.######} %   ADD_21_0 = {2:0.######} mm/min{3}',
        $index, $data.Value40[$index], $data.Value21[$index],
        $(if ([float]::IsFinite($data.Value40[$index]) -and [float]::IsFinite($data.Value21[$index])) { '' } else { '   (無効レコード)' }))
}

function Export-NCLogViewerCsv {
    <#
    .SYNOPSIS
        表示中のファイルを、表示中のレイアウトで CSV に出力する (Export-NCLogValue を使用)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $data = $Context.Data
    if ($null -eq $data) { return }
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
    $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($data.Path)
    $dialog.FileName = [System.IO.Path]::GetFileNameWithoutExtension($data.Path) + '.csv'
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
