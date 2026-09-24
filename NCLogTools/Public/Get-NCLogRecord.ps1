function Get-NCLogRecord {
    <#
    .SYNOPSIS
        NCLog バイナリファイル (.BIN) から ADD_40_0 / ADD_21_0 をレコード単位で読み出す。

    .DESCRIPTION
        ワイヤレーザー3Dプリンターの NCLog バイナリファイルを先頭からストリームで読み、
        1レコードごとに次の2値を「ペアのまま」NCLog.Record オブジェクトとして出力します。

        - Value40 = ADD_40_0: amPrcLg_output_pwr (実レーザー出力パワー %)
        - Value21 = ADD_21_0: realWirFeed_vel    (実ワイヤフィード速度 mm/min)

        既定のバイナリレイアウト (Get-NCLogFileInfo で実ファイルを確認してください):
            [Header 0x20 byte][Record 16 byte][Record 16 byte]...
            Record 内: +4 = ADD_40_0 (float32 LE), +8 = ADD_21_0 (float32 LE)

        どちらか一方でも NaN / ±Infinity のレコードはレコードごと除外するため、
        2値の対応がずれることはありません。RecordNumber はファイル内の実レコード番号 (0 始まり) です。

        オブジェクトは読み込みながら逐次出力されるため、Select-Object -First などで
        途中終了した場合も残りは読まずにファイルを閉じます。

    .PARAMETER Path
        NCLog ファイルのパス。ワイルドカード可。別名: FilePath

    .PARAMETER LiteralPath
        ワイルドカードとして解釈しないパス ('[' などを含むファイル名用)。
        Get-ChildItem の出力をパイプすると、このパラメーターにバインドされます。

    .PARAMETER HideZeros
        Value40 と Value21 が両方 0 のレコードを除外します。

    .PARAMETER MaxRecords
        出力する最大レコード数 (全ファイル合計)。既定: 無制限

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
        NCLog.Record (SourceFile, RecordNumber, Value40, Value21)

    .EXAMPLE
        Get-NCLogRecord -Path 'C:\Logs\NCLog_00000000_00003044.BIN'

        1ファイルの全レコードを取得します。

    .EXAMPLE
        Get-ChildItem 'C:\Logs' -Filter 'NCLog*.BIN' | Get-NCLogRecord -HideZeros |
            Where-Object Value40 -gt 50

        フォルダ内の全ログから、レーザー出力 50% 超のレコードを抽出します。

    .EXAMPLE
        Get-NCLogRecord 'C:\Logs\NCLog_*.BIN' | Select-Object -First 100

        先頭 100 件だけ読みます (残りのデータは読み込みません)。

    .LINK
        Export-NCLogValue

    .LINK
        Measure-NCLogRecord

    .LINK
        Get-NCLogFileInfo
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType('NCLog.Record')]
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

        [switch]$HideZeros,

        [ValidateRange(1, [long]::MaxValue)]
        [long]$MaxRecords = [long]::MaxValue,

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
        Assert-NCLogLayout -Cmdlet $PSCmdlet -RecordSize $RecordSize `
            -Value40Offset $Value40Offset -Value21Offset $Value21Offset

        $emitted = 0L
        # 1回の Read で約 1MB (レコード境界に揃える) を読み、システムコール回数を抑える
        $chunkRecords = [int][Math]::Max(1, [Math]::Floor(1MB / $RecordSize))
        $buffer = [byte[]]::new($chunkRecords * $RecordSize)
    }

    process {
        if ($emitted -ge $MaxRecords) { return }

        $targets = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            foreach ($p in $LiteralPath) { Resolve-NCLogPath -Cmdlet $PSCmdlet -InputPath $p -Literal }
        }
        else {
            foreach ($p in $Path) { Resolve-NCLogPath -Cmdlet $PSCmdlet -InputPath $p }
        }

        foreach ($file in $targets) {
            if ($emitted -ge $MaxRecords) { break }
            Write-Verbose "処理中: $file"

            $stream = $null
            try {
                $stream = Open-NCLogFile -LiteralFilePath $file
                $length = $stream.Length
                if ($length -lt $HeaderSize + $RecordSize) {
                    Write-Warning "レコードが1件もありません (サイズ $length byte): $file"
                    continue
                }

                $recordCount = [long][Math]::Floor(($length - $HeaderSize) / $RecordSize)
                $trailing = ($length - $HeaderSize) % $RecordSize
                if ($trailing -ne 0) {
                    Write-Warning "末尾の $trailing byte は不完全なレコードのため無視します: $file"
                }
                Write-Verbose "レコード数: $recordCount"

                [void]$stream.Seek($HeaderSize, [System.IO.SeekOrigin]::Begin)
                $skipped = 0L
                $i = 0L

                while ($i -lt $recordCount -and $emitted -lt $MaxRecords) {
                    $inChunk = [int][Math]::Min($chunkRecords, $recordCount - $i)
                    Read-NCLogBlock -Stream $stream -Buffer $buffer -Count ($inChunk * $RecordSize)

                    for ($k = 0; $k -lt $inChunk; $k++) {
                        $base = $k * $RecordSize
                        $recordNumber = $i
                        $i++

                        $v40 = [System.BitConverter]::ToSingle($buffer, $base + $Value40Offset)
                        $v21 = [System.BitConverter]::ToSingle($buffer, $base + $Value21Offset)

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
                            SourceFile   = $file
                            RecordNumber = $recordNumber
                            Value40      = $v40
                            Value21      = $v21
                        }

                        if ($emitted -ge $MaxRecords) {
                            Write-Verbose "MaxRecords ($MaxRecords) に達したため読み込みを終了します。"
                            break
                        }
                    }
                }

                if ($skipped -gt 0) {
                    Write-Verbose "NaN/Infinity を含むため除外したレコード: $skipped"
                }
            }
            catch [System.IO.IOException], [System.UnauthorizedAccessException], [System.Security.SecurityException] {
                # IOException には EndOfStreamException / FileNotFoundException なども含まれる
                $PSCmdlet.WriteError((New-NCLogErrorRecord -Exception $_.Exception -ErrorId 'NCLogReadFailed' `
                            -Category ReadError -TargetObject $file))
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
    }
}
