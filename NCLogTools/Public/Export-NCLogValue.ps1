function Export-NCLogValue {
    <#
    .SYNOPSIS
        NCLog バイナリファイルから ADD_40_0 / ADD_21_0 を抽出し、CSV/TSV/JSON/Raw/Table で出力する。

    .DESCRIPTION
        Get-NCLogRecord で読み出したレコードを指定形式に変換し、パイプライン (画面) または
        ファイルに出力します。-Statistics 指定時は Measure-NCLogRecord の結果をホストに表示します。

        ファイル出力時の安全策:
        - 既存ファイルは -Force を指定しない限り上書きしません。
        - -WhatIf / -Confirm に対応しています。
        - 既定の文字コードは utf8BOM (Windows 版 Excel で直接開いても文字化けしない) です。

    .PARAMETER Path
        NCLog ファイルのパス。ワイルドカード可。別名: FilePath

    .PARAMETER LiteralPath
        ワイルドカードとして解釈しないパス。Get-ChildItem の出力はここにバインドされます。

    .PARAMETER OutputPath
        出力ファイルのパス。省略時はパイプラインに出力します。

    .PARAMETER Format
        出力形式: 'Table'(既定), 'CSV', 'TSV', 'JSON', 'Raw'。-AsObject 指定時は無視されます。
        Raw は "RecordNumber,Value40,Value21" 形式 (InvariantCulture) の1行1レコードです。

    .PARAMETER Statistics
        ファイルごとの統計情報をホストに表示します (-HideZeros / -MaxRecords 適用後のデータが対象)。

    .PARAMETER HideZeros
        Value40 と Value21 が両方 0 のレコードを除外します。

    .PARAMETER MaxRecords
        出力する最大レコード数 (全ファイル合計)。既定: 無制限

    .PARAMETER AsObject
        NCLog.Record オブジェクトをそのまま返します (Format / OutputPath より優先)。

    .PARAMETER Force
        OutputPath に既存ファイルがあっても上書きします。

    .PARAMETER Encoding
        出力ファイルの文字コード。既定 utf8BOM。

    .PARAMETER HeaderSize
        ファイル先頭ヘッダーのバイト数。既定 0x20 (32)。

    .PARAMETER RecordSize
        1レコードのバイト数。既定 16。

    .PARAMETER Value40Offset
        レコード先頭から ADD_40_0 までのバイトオフセット。既定 4。

    .PARAMETER Value21Offset
        レコード先頭から ADD_21_0 までのバイトオフセット。既定 8。

    .INPUTS
        System.String, System.IO.FileInfo

    .OUTPUTS
        System.String (CSV/TSV/JSON/Raw), 書式データ (Table), NCLog.Record (-AsObject)

    .EXAMPLE
        Export-NCLogValue -Path 'C:\Logs\NCLog_*.BIN' -Format CSV -OutputPath .\out.csv -Statistics

        統計を表示しつつ、全ログを1つの CSV に保存します。

    .EXAMPLE
        Get-ChildItem 'C:\Logs' -Filter 'NCLog*.BIN' |
            Export-NCLogValue -Format JSON -OutputPath .\all.json -Force

        既存の JSON を上書きして保存します。

    .EXAMPLE
        $csv = Export-NCLogValue 'NCLog_00000000_00003044.BIN' -Format CSV
        $csv | Set-Clipboard

        CSV 文字列を変数に受け取り、クリップボードへコピーします。

    .LINK
        Get-NCLogRecord

    .LINK
        Measure-NCLogRecord
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
    [OutputType('System.String', 'NCLog.Record')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path',
            ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FilePath')]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string[]]$Path,

        [Parameter(Mandatory, ParameterSetName = 'LiteralPath',
            ValueFromPipelineByPropertyName)]
        [Alias('PSPath', 'LP')]
        [ValidateNotNullOrEmpty()]
        [string[]]$LiteralPath,

        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [ValidateSet('Table', 'CSV', 'TSV', 'JSON', 'Raw')]
        [string]$Format = 'Table',

        [switch]$Statistics,

        [switch]$HideZeros,

        [ValidateRange(1, [long]::MaxValue)]
        [long]$MaxRecords = [long]::MaxValue,

        [switch]$AsObject,

        [switch]$Force,

        [ValidateSet('utf8', 'utf8BOM', 'utf8NoBOM', 'unicode')]
        [string]$Encoding = 'utf8BOM',

        [ValidateRange(0, 1MB)]
        [int]$HeaderSize = 0x20,

        [ValidateRange(8, 64KB)]
        [int]$RecordSize = 16,

        [ValidateRange(0, 64KB)]
        [int]$Value40Offset = 4,

        [ValidateRange(0, 64KB)]
        [int]$Value21Offset = 8
    )

    begin {
        # レイアウト不正はファイルを読む前に検出する
        Assert-NCLogLayout -Cmdlet $PSCmdlet -RecordSize $RecordSize `
            -Value40Offset $Value40Offset -Value21Offset $Value21Offset

        $records = [System.Collections.Generic.List[object]]::new()

        # Get-NCLogRecord にそのまま渡すパラメーター
        $readerParams = @{}
        foreach ($name in 'HideZeros', 'HeaderSize', 'RecordSize', 'Value40Offset', 'Value21Offset') {
            if ($PSBoundParameters.ContainsKey($name)) { $readerParams[$name] = $PSBoundParameters[$name] }
        }
    }

    process {
        $remaining = $MaxRecords - $records.Count
        if ($remaining -le 0) { return }

        if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            $readerParams['LiteralPath'] = $LiteralPath
        }
        else {
            $readerParams['Path'] = $Path
        }

        # 呼び出し元の -ErrorAction / -Verbose は優先度変数経由で Get-NCLogRecord に伝わる
        foreach ($record in (Get-NCLogRecord @readerParams -MaxRecords $remaining)) {
            $records.Add($record)
        }
    }

    end {
        if ($records.Count -eq 0) {
            Write-Warning '処理対象のデータがありません'
            return
        }

        if ($Statistics) {
            Write-NCLogStatistic -Statistic @($records | Measure-NCLogRecord -GroupBy File)
        }

        if ($AsObject) {
            return $records.ToArray()
        }

        $columns = 'SourceFile', 'RecordNumber', 'Value40', 'Value21'
        $ic = [System.Globalization.CultureInfo]::InvariantCulture

        $rendered = switch ($Format) {
            'Table' { $records | Format-Table -Property $columns -AutoSize }
            'CSV' { $records | Select-Object -Property $columns | ConvertTo-Csv -NoTypeInformation }
            'TSV' { $records | Select-Object -Property $columns | ConvertTo-Csv -NoTypeInformation -Delimiter "`t" }
            'JSON' { $records | Select-Object -Property $columns | ConvertTo-Json -AsArray }
            'Raw' {
                foreach ($r in $records) {
                    [string]::Format($ic, '{0},{1},{2}', $r.RecordNumber, $r.Value40, $r.Value21)
                }
            }
        }

        if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
            # Write-Host ではなくパイプラインに出すことで、変数代入・リダイレクトが可能
            return $rendered
        }

        $fullOutputPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

        $parent = [System.IO.Path]::GetDirectoryName($fullOutputPath)
        if ($parent -and -not [System.IO.Directory]::Exists($parent)) {
            $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                        -Exception ([System.IO.DirectoryNotFoundException]::new("出力先フォルダが存在しません: $parent")) `
                        -ErrorId 'OutputDirectoryNotFound' -Category ObjectNotFound -TargetObject $parent))
        }
        if ([System.IO.Directory]::Exists($fullOutputPath)) {
            $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                        -Exception ([System.IO.IOException]::new("出力先がフォルダです: $fullOutputPath")) `
                        -ErrorId 'OutputPathIsDirectory' -Category InvalidArgument -TargetObject $fullOutputPath))
        }
        if ([System.IO.File]::Exists($fullOutputPath) -and -not $Force) {
            $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                        -Exception ([System.IO.IOException]::new("出力ファイルが既に存在します。上書きするには -Force を指定してください: $fullOutputPath")) `
                        -ErrorId 'OutputFileExists' -Category ResourceExists -TargetObject $fullOutputPath))
        }

        if ($PSCmdlet.ShouldProcess($fullOutputPath, "$Format 形式で $($records.Count) 件を出力")) {
            try {
                $rendered | Out-File -LiteralPath $fullOutputPath -Encoding $Encoding -Width 4096 -Force -ErrorAction Stop
            }
            catch {
                $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord -Exception $_.Exception `
                            -ErrorId 'OutputWriteFailed' -Category WriteError -TargetObject $fullOutputPath))
            }
            Write-Host "✓ 保存完了: $fullOutputPath ($($records.Count) 件)" -ForegroundColor Green
        }
    }
}
