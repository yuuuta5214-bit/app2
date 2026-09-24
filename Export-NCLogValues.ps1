#Requires -Version 7.2

<#
.SYNOPSIS
    NCログ (.BIN) から ADD_40_0 と ADD_21_0 を抽出するCLIツール

.DESCRIPTION
    ワイヤレーザー3Dプリンターの NCLog バイナリファイル (.BIN) から、
    同じレコードの以下2つのパラメータを「ペアのまま」抽出します。

    - ADD_40_0: amPrcLg_output_pwr (実レーザー出力パワー %)
    - ADD_21_0: realWirFeed_vel    (実ワイヤフィード速度 mm/min)

    既定のバイナリレイアウト (実ファイルで要確認):
        [Header 0x20 byte][Record 16 byte][Record 16 byte]...
        Record 内: +4 = ADD_40_0 (float32 LE), +8 = ADD_21_0 (float32 LE)

    どちらか一方でも NaN / ±Infinity のレコードはレコード単位で除外するため、
    2つの値の対応関係が崩れることはありません。RecordNumber はファイル内の
    実レコード番号 (0 始まり) です。

    ファイルはストリームで読み込むため、大きなログでもメモリを消費しません。
    ロガーが書き込み中のファイルも読み取れるよう FileShare.ReadWrite で開きます。

.PARAMETER Path
    NCログバイナリファイルのパス。ワイルドカード可。パイプライン入力対応
    (Get-ChildItem の出力をそのまま渡せます)。別名: FilePath

.PARAMETER LiteralPath
    ワイルドカードとして解釈しないパス ('[' などを含むファイル名用)。

.PARAMETER OutputPath
    出力ファイルのパス。省略時はパイプライン (画面) に出力します。

.PARAMETER Format
    出力形式: 'Table'(既定), 'CSV', 'TSV', 'JSON', 'Raw'
    -AsObject 指定時は無視されます。

.PARAMETER Statistics
    統計情報 (件数・最小・最大・平均・標準偏差) をファイルごとに表示します。
    統計は -HideZeros / -MaxRecords 適用後の「出力されるレコード」を対象とします。

.PARAMETER HideZeros
    ADD_40_0 と ADD_21_0 が両方 0 のレコードを除外します。

.PARAMETER MaxRecords
    出力する最大レコード数 (全ファイル合計)。既定: 無制限

.PARAMETER AsObject
    PowerShell オブジェクトをパイプラインに返します (Format / OutputPath より優先)。

.PARAMETER Force
    OutputPath に既存ファイルがあっても上書きします。

.PARAMETER Encoding
    出力ファイルの文字コード。既定 utf8BOM (Windows 版 Excel で文字化けしない)。

.PARAMETER HeaderSize
    ファイル先頭ヘッダーのバイト数。既定 0x20 (32)。

.PARAMETER RecordSize
    1レコードのバイト数。既定 16。

.PARAMETER Value40Offset
    レコード先頭から ADD_40_0 までのオフセット。既定 4。

.PARAMETER Value21Offset
    レコード先頭から ADD_21_0 までのオフセット。既定 8。

.INPUTS
    System.String, System.IO.FileInfo

.OUTPUTS
    PSCustomObject (NCLog.Record) / System.String

.EXAMPLE
    .\Export-NCLogValues.ps1 -Path 'NCLog_00000000_00003044.BIN'

    テーブル形式で画面表示します。

.EXAMPLE
    .\Export-NCLogValues.ps1 -Path 'C:\Logs\NCLog_*.BIN' -OutputPath 'output.csv' -Format CSV -Statistics

    ワイルドカードで複数ファイルを処理し、統計を表示して CSV に保存します。

.EXAMPLE
    Get-ChildItem 'C:\Logs' -Filter 'NCLog*.BIN' |
        .\Export-NCLogValues.ps1 -OutputPath 'combined.json' -Format JSON -Force

    パイプラインで一括処理し、既存の JSON を上書きします。

.EXAMPLE
    $data = .\Export-NCLogValues.ps1 -Path 'NCLog_00000000_00003044.BIN' -AsObject
    $data | Sort-Object Value40 -Descending | Select-Object -First 10

    オブジェクトとして取得し、PowerShell で後処理します。

.NOTES
    バージョン: 2.0
    変更点 (1.0 から):
      - NaN 除外で ADD_40_0 / ADD_21_0 の対応がずれる不具合を修正
      - ワイルドカード / 相対パス / パイプライン (FileInfo) の解決を修正
      - 文字列出力を Write-Host ではなくパイプラインへ出力
      - ストリーム読み込み化、配列 += を List に置き換え (大容量対応)
      - 出力ファイルの無断上書きを防止 (-Force 必須)
      - 実体のない Timestamp 列を廃止し、SourceFile 列を追加
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
[OutputType([pscustomobject], [string])]
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

    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxRecords = [int]::MaxValue,

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
    Set-StrictMode -Version 3.0

    foreach ($offset in $Value40Offset, $Value21Offset) {
        if ($offset + 4 -gt $RecordSize) {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentOutOfRangeException]::new('Value40Offset/Value21Offset',
                        "オフセット $offset + 4 byte がレコードサイズ $RecordSize を超えています。"),
                    'InvalidRecordLayout',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $offset))
        }
    }

    # Windows (x64/ARM64) は常にリトルエンディアン。念のため前提を検証する
    if (-not [System.BitConverter]::IsLittleEndian) {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.PlatformNotSupportedException]::new('ビッグエンディアン環境はサポートしていません。'),
                'BigEndianNotSupported',
                [System.Management.Automation.ErrorCategory]::NotImplemented,
                $null))
    }

    $allObjects = [System.Collections.Generic.List[object]]::new()
    $limitReached = $false

    function New-NCLogErrorRecord {
        <#
        .SYNOPSIS
            ErrorRecord を生成する内部ヘルパー。
        #>
        param(
            [Parameter(Mandatory)][System.Exception]$Exception,
            [Parameter(Mandatory)][string]$ErrorId,
            [Parameter(Mandatory)][System.Management.Automation.ErrorCategory]$Category,
            [object]$TargetObject
        )
        [System.Management.Automation.ErrorRecord]::new($Exception, $ErrorId, $Category, $TargetObject)
    }

    function Resolve-NCLogPath {
        <#
        .SYNOPSIS
            PowerShell のパス (ワイルドカード・相対パス・PSDrive) を実ファイルパスへ解決する。
        .NOTES
            .NET の API は PowerShell の $PWD ではなくプロセスのカレントディレクトリを
            基準にするため、必ずここで絶対パスに変換してから渡す。
        #>
        param(
            [Parameter(Mandatory)][string]$InputPath,
            [switch]$Literal
        )

        $provider = $null
        $drive = $null
        try {
            if ($Literal) {
                $resolved = @($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
                        $InputPath, [ref]$provider, [ref]$drive))
            }
            else {
                $resolved = @($PSCmdlet.SessionState.Path.GetResolvedProviderPathFromPSPath(
                        $InputPath, [ref]$provider))
            }
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            $PSCmdlet.WriteError((New-NCLogErrorRecord -Exception $_.Exception -ErrorId 'PathNotFound' `
                        -Category ObjectNotFound -TargetObject $InputPath))
            return
        }

        if ($provider.Name -ne 'FileSystem') {
            $PSCmdlet.WriteError((New-NCLogErrorRecord `
                        -Exception ([System.ArgumentException]::new("ファイルシステムのパスではありません: $InputPath")) `
                        -ErrorId 'NotFileSystemPath' -Category InvalidArgument -TargetObject $InputPath))
            return
        }

        foreach ($item in $resolved) {
            if ([System.IO.File]::Exists($item)) {
                $item
            }
            else {
                $PSCmdlet.WriteError((New-NCLogErrorRecord `
                            -Exception ([System.IO.FileNotFoundException]::new("ファイルが見つからないか、ディレクトリです: $item", $item)) `
                            -ErrorId 'FileNotFound' -Category ObjectNotFound -TargetObject $item))
            }
        }
    }

    function Read-NCLogRecord {
        <#
        .SYNOPSIS
            NCLog ファイルをストリームで読み、有効なレコードを最大 Limit 件まで出力する。
        .NOTES
            HideZeros と件数上限をここで適用することで、上限到達時に残りを読まずに済む。
        #>
        param(
            [Parameter(Mandatory)][string]$LiteralFilePath,
            [Parameter(Mandatory)][long]$Limit
        )

        $stream = [System.IO.FileStream]::new(
            $LiteralFilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite,   # ロガーが書き込み中でも読めるように
            64KB,
            [System.IO.FileOptions]::SequentialScan)
        try {
            $length = $stream.Length
            if ($length -lt $HeaderSize + $RecordSize) {
                Write-Warning "レコードが1件もありません (サイズ $length byte): $LiteralFilePath"
                return
            }

            $recordCount = [long][Math]::Floor(($length - $HeaderSize) / $RecordSize)
            $trailing = ($length - $HeaderSize) % $RecordSize
            if ($trailing -ne 0) {
                Write-Warning "末尾の $trailing byte は不完全なレコードのため無視します: $LiteralFilePath"
            }
            Write-Verbose "レコード数: $recordCount ($LiteralFilePath)"

            [void]$stream.Seek($HeaderSize, [System.IO.SeekOrigin]::Begin)
            $buffer = [byte[]]::new($RecordSize)
            $skipped = 0L
            $emitted = 0L

            for ($i = 0L; $i -lt $recordCount -and $emitted -lt $Limit; $i++) {
                # Stream.Read は要求より少なく返すことがあるため、1レコード分揃うまで読む
                $filled = 0
                while ($filled -lt $RecordSize) {
                    $n = $stream.Read($buffer, $filled, $RecordSize - $filled)
                    if ($n -le 0) {
                        throw [System.IO.EndOfStreamException]::new(
                            "レコード $i の途中でファイルが終了しました (読み取り中に切り詰められた可能性があります)。")
                    }
                    $filled += $n
                }

                $v40 = [System.BitConverter]::ToSingle($buffer, $Value40Offset)
                $v21 = [System.BitConverter]::ToSingle($buffer, $Value21Offset)

                # 片方でも無効ならレコードごと捨てる (列ずれ防止)
                if (-not ([float]::IsFinite($v40) -and [float]::IsFinite($v21))) {
                    $skipped++
                    continue
                }
                if ($HideZeros -and $v40 -eq 0 -and $v21 -eq 0) {
                    continue
                }

                $emitted++
                [pscustomobject]@{
                    PSTypeName   = 'NCLog.Record'
                    SourceFile   = $LiteralFilePath
                    RecordNumber = $i
                    Value40      = $v40
                    Value21      = $v21
                }
            }

            if ($skipped -gt 0) {
                Write-Verbose "NaN/Infinity を含むため除外したレコード: $skipped"
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    function Get-NCLogStatistic {
        <#
        .SYNOPSIS
            数値列の件数・最小・最大・平均・標準偏差 (母標準偏差) を1パスで計算する。
        #>
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Value
        )

        if ($Value.Count -eq 0) { return $null }

        # Welford 法: 1パスで数値的に安定
        $n = 0L; $mean = 0.0; $m2 = 0.0
        $min = [double]::PositiveInfinity; $max = [double]::NegativeInfinity
        foreach ($x in $Value) {
            $n++
            $delta = $x - $mean
            $mean += $delta / $n
            $m2 += $delta * ($x - $mean)
            if ($x -lt $min) { $min = $x }
            if ($x -gt $max) { $max = $x }
        }

        [pscustomobject]@{
            Count   = $n
            Minimum = $min
            Maximum = $max
            Average = $mean
            StdDev  = [Math]::Sqrt($m2 / $n)
        }
    }

    function Write-NCLogStatistic {
        <#
        .SYNOPSIS
            統計情報をホストに表示する (データ出力ストリームは汚さない)。
        #>
        param(
            [Parameter(Mandatory)][string]$Label,
            [AllowNull()][object]$Stat
        )

        Write-Host $Label
        if ($null -eq $Stat) {
            Write-Host '  (データなし)'
            return
        }
        $ic = [System.Globalization.CultureInfo]::InvariantCulture
        Write-Host ([string]::Format($ic, '  件数:      {0}', $Stat.Count))
        Write-Host ([string]::Format($ic, '  最小:      {0:F6}', $Stat.Minimum))
        Write-Host ([string]::Format($ic, '  最大:      {0:F6}', $Stat.Maximum))
        Write-Host ([string]::Format($ic, '  平均:      {0:F6}', $Stat.Average))
        Write-Host ([string]::Format($ic, '  標準偏差:  {0:F6}', $Stat.StdDev))
    }
}

process {
    if ($limitReached) { return }

    $targets = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
        foreach ($p in $LiteralPath) { Resolve-NCLogPath -InputPath $p -Literal }
    }
    else {
        foreach ($p in $Path) { Resolve-NCLogPath -InputPath $p }
    }

    foreach ($file in $targets) {
        if ($limitReached) { break }
        Write-Verbose "処理中: $file"

        $remaining = [long]$MaxRecords - $allObjects.Count
        $fileObjects = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($record in (Read-NCLogRecord -LiteralFilePath $file -Limit $remaining)) {
                $fileObjects.Add($record)
            }
        }
        catch {
            $PSCmdlet.WriteError((New-NCLogErrorRecord -Exception $_.Exception -ErrorId 'NCLogReadFailed' `
                        -Category ReadError -TargetObject $file))
            continue
        }

        $allObjects.AddRange($fileObjects)
        Write-Verbose "抽出件数: $($fileObjects.Count) ($file)"
        if ($allObjects.Count -ge $MaxRecords) {
            $limitReached = $true
            Write-Verbose "MaxRecords ($MaxRecords) に達したため、以降のファイルは処理しません。"
        }

        if ($Statistics) {
            Write-Host ''
            Write-Host "📊 統計情報: $file" -ForegroundColor Cyan
            Write-Host ('─' * 60) -ForegroundColor Cyan
            Write-NCLogStatistic -Label 'ADD_40_0 (レーザー出力パワー %)' `
                -Stat (Get-NCLogStatistic -Value @(foreach ($r in $fileObjects) { $r.Value40 }))
            Write-Host ''
            Write-NCLogStatistic -Label 'ADD_21_0 (ワイヤフィード速度 mm/min)' `
                -Stat (Get-NCLogStatistic -Value @(foreach ($r in $fileObjects) { $r.Value21 }))
            Write-Host ''
        }
    }
}

end {
    if ($allObjects.Count -eq 0) {
        Write-Warning '処理対象のデータがありません'
        return
    }

    if ($AsObject) {
        return $allObjects.ToArray()
    }

    $columns = 'SourceFile', 'RecordNumber', 'Value40', 'Value21'

    # 形式ごとの文字列/書式データを生成 (出力先は後で決める)
    $rendered = switch ($Format) {
        'Table' { $allObjects | Format-Table -Property $columns -AutoSize }
        'CSV'   { $allObjects | ConvertTo-Csv -NoTypeInformation }
        'TSV'   { $allObjects | ConvertTo-Csv -NoTypeInformation -Delimiter "`t" }
        'JSON'  { $allObjects | Select-Object -Property $columns | ConvertTo-Json -AsArray }
        'Raw'   {
            $ic = [System.Globalization.CultureInfo]::InvariantCulture
            foreach ($obj in $allObjects) {
                [string]::Format($ic, '{0},{1},{2}', $obj.RecordNumber, $obj.Value40, $obj.Value21)
            }
        }
    }

    if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
        # Write-Host ではなくパイプラインに出すことで、変数代入・リダイレクトが可能になる
        $rendered
        return
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

    if ($PSCmdlet.ShouldProcess($fullOutputPath, "$Format 形式で $($allObjects.Count) 件を出力")) {
        try {
            $rendered | Out-File -LiteralPath $fullOutputPath -Encoding $Encoding -Width 4096 -Force -ErrorAction Stop
            Write-Host "✓ 保存完了: $fullOutputPath ($($allObjects.Count) 件)" -ForegroundColor Green
        }
        catch {
            $PSCmdlet.ThrowTerminatingError((New-NCLogErrorRecord -Exception $_.Exception `
                        -ErrorId 'OutputWriteFailed' -Category WriteError -TargetObject $fullOutputPath))
        }
    }
}
