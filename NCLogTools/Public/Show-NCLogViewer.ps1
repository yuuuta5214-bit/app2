function Show-NCLogViewer {
    <#
    .SYNOPSIS
        NCLog バイナリファイル (.BIN) を GUI (WPF) で閲覧する。Windows 専用。

    .DESCRIPTION
        NCLog ファイルを開き (複数可)、ファイルごとに CSV の出力ファイル名を決めて一括出力するウィンドウを起動します。
        ウィンドウを閉じるまでコマンドは戻りません。

        左側 (作業順):
          ① ファイル一覧   : 開いたファイルと出力ファイル名・状態。出力できる行は緑。
          ②③ 出力ファイル名: グラフをクリックした位置のレーザー出力・ワイヤ速度と、手入力の割合から
                             「レーザー出力W_ワイヤ速度mm-min_割合%.csv」を作ります
                             (ファイル名に '/' は使えないため mm/min は mm-min)。
          ④ 一括 CSV 出力  : 出力できるファイルをすべて CSV に出力します。
        右側のタブ:
          グラフ       : ADD_40_0 と ADD_21_0 の推移。クリックで値を取得、ホイールで拡大・縮小、ドラッグで移動。
          レコード     : レコード番号・アドレス・ADD_40_0・ADD_21_0 の一覧。無効レコードは赤。
          16進ダンプ・ファイル情報は [ツール] メニューで表示します。

        ファイルは読み取り専用・共有読み取りで開き、変更しません。
        画面上でレイアウト (ヘッダー / レコードサイズ / 各値の位置) を変えて再解析でき、
        表示中のレイアウトで CSV に出力できます (Export-NCLogValue を使用)。

        ファイルはメモリに読み込むため、16MB を超えるファイルは開けません。
        パスを省略した場合は空のウィンドウを開きます ([開く] またはドラッグ＆ドロップで指定)。
        同時に開けるのは 100 ファイルまでです。

    .PARAMETER Path
        開く NCLog ファイルのパス (複数可)。ワイルドカード可。別名: FilePath

    .PARAMETER LiteralPath
        ワイルドカードとして解釈しないパス (複数可。'[' などを含むファイル名用)。

    .PARAMETER HeaderSize
        起動時のヘッダーのバイト数。既定 0x20 (32)。画面の [既定値] ボタンでこの値に戻ります。

    .PARAMETER RecordSize
        起動時の1レコードのバイト数。既定 16。

    .PARAMETER Value40Offset
        起動時の、レコード先頭から ADD_40_0 までのバイトオフセット。既定 4。

    .PARAMETER Value21Offset
        起動時の、レコード先頭から ADD_21_0 までのバイトオフセット。既定 8。

    .INPUTS
        None

    .OUTPUTS
        None

    .EXAMPLE
        Show-NCLogViewer 'C:\Logs\NCLog_00000000_00003044.BIN'

        ファイルを開いてビューアーを表示します。

    .EXAMPLE
        Show-NCLogViewer 'C:\Logs\NCLog_*.BIN'

        一致するファイルをすべて開きます。

    .EXAMPLE
        Show-NCLogViewer

        空のビューアーを表示します。[開く] ボタンまたはドラッグ＆ドロップでファイルを指定します。

    .EXAMPLE
        Show-NCLogViewer -LiteralPath '.\NCLog[1].BIN' -RecordSize 20 -Value21Offset 12

        レコード長 20 byte・ADD_21_0 が +12 のレイアウトで開きます。

    .NOTES
        エクスプローラーからは NCLogViewer.cmd (ダブルクリック / ドラッグ＆ドロップ) で起動できます。

    .LINK
        Get-NCLogRecord

    .LINK
        Get-NCLogFileInfo

    .LINK
        Export-NCLogValue
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Path')]
        [Alias('FilePath')]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string[]]$Path,

        [Parameter(Mandatory, ParameterSetName = 'LiteralPath')]
        [Alias('PSPath', 'LP')]
        [ValidateNotNullOrEmpty()]
        [string[]]$LiteralPath,

        [ValidateRange(0, 1MB)]
        [int]$HeaderSize = 0x20,

        [ValidateRange(8, 64KB)]
        [int]$RecordSize = 16,

        [ValidateRange(0, 64KB)]
        [int]$Value40Offset = 4,

        [ValidateRange(0, 64KB)]
        [int]$Value21Offset = 8
    )

    Assert-NCLogLayout -Cmdlet $PSCmdlet -RecordSize $RecordSize `
        -Value40Offset $Value40Offset -Value21Offset $Value21Offset

    $files = [string[]]@()
    if ($PSBoundParameters.ContainsKey('Path') -or $PSBoundParameters.ContainsKey('LiteralPath')) {
        $literal = $PSCmdlet.ParameterSetName -eq 'LiteralPath'
        $inputs = if ($literal) { $LiteralPath } else { $Path }
        $files = [string[]]@(
            foreach ($p in $inputs) { Resolve-NCLogPath -Cmdlet $PSCmdlet -InputPath $p -Literal:$literal }
        )
        $files = [string[]]@($files | Select-Object -Unique)
        # 1つも解決できなかった場合は Resolve-NCLogPath がエラーを報告済み。
        # 一部だけ解決できた場合は、エラーを報告したうえで解決できたファイルを開く
        if ($files.Count -eq 0) { return }
    }

    if (-not $IsWindows) {
        $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                    -Exception ([System.PlatformNotSupportedException]::new('NCLog Viewer は Windows 専用です (WPF を使用)。')) `
                    -ErrorId 'ViewerRequiresWindows' -Category NotImplemented -TargetObject $null))
    }

    try {
        Start-NCLogViewerWindow -LiteralFilePath $files -HeaderSize $HeaderSize -RecordSize $RecordSize `
            -Value40Offset $Value40Offset -Value21Offset $Value21Offset
    }
    catch {
        $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord -Exception $_.Exception `
                    -ErrorId 'ViewerFailed' -Category InvalidOperation -TargetObject $files))
    }
}
