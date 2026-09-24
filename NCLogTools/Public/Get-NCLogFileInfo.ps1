function Get-NCLogFileInfo {
    <#
    .SYNOPSIS
        NCLog ファイルの構造 (ヘッダー・レコード数・先頭レコードの生データ) を表示し、レイアウト検証を支援する。

    .DESCRIPTION
        Get-NCLogRecord の既定レイアウト (ヘッダー 0x20 byte / 16 byte レコード / +4 と +8 が float32)
        は実機のログで検証されていません。このコマンドは次の情報を返すので、制御装置の画面値や
        既知の加工条件と突き合わせてオフセットを確認できます。

        - ファイルサイズ、推定レコード数、末尾の端数バイト
        - ヘッダーの16進ダンプと、4 byte ごとの Int32 / Single 解釈
        - 先頭 SampleCount 件のレコードについて、4 byte ごとの Int32 / Single 解釈

        ファイルは読み取り専用・共有読み取りで開き、先頭部分だけを読みます。

    .PARAMETER Path
        NCLog ファイルのパス。ワイルドカード可。別名: FilePath

    .PARAMETER LiteralPath
        ワイルドカードとして解釈しないパス。

    .PARAMETER SampleCount
        生データを表示するレコード数。既定 5。

    .PARAMETER HeaderSize
        ヘッダーのバイト数 (仮定値)。既定 0x20 (32)。

    .PARAMETER RecordSize
        1レコードのバイト数 (仮定値)。既定 16。4 の倍数である必要があります。

    .INPUTS
        System.String, System.IO.FileInfo

    .OUTPUTS
        NCLog.FileInfo

    .EXAMPLE
        $info = Get-NCLogFileInfo 'C:\Logs\NCLog_00000000_00003044.BIN'
        $info.Samples | Format-Table RecordNumber, Hex
        $info.Samples | ForEach-Object { $_.Words } | Format-Table

        先頭5レコードを 4 byte ごとに Int32 / Single として表示し、どの位置が
        レーザー出力 (%) やワイヤ速度 (mm/min) らしい値かを確認します。

    .EXAMPLE
        Get-NCLogFileInfo .\NCLog.BIN -RecordSize 20 | Select-Object RecordCount, TrailingBytes

        レコード長 20 byte と仮定したときに端数が出ないかを確認します
        (正しいレコード長なら TrailingBytes は通常 0 になります)。

    .LINK
        Get-NCLogRecord
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType('NCLog.FileInfo')]
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

        [ValidateRange(0, 1000)]
        [int]$SampleCount = 5,

        [ValidateRange(0, 1MB)]
        [int]$HeaderSize = 0x20,

        [ValidateRange(8, 64KB)]
        [ValidateScript({ $_ % 4 -eq 0 }, ErrorMessage = 'RecordSize は 4 の倍数を指定してください: {0}')]
        [int]$RecordSize = 16
    )

    begin {
        function ConvertTo-NCLogWord {
            # 4 byte 境界ごとに Int32 / Single として解釈する
            param([byte[]]$Bytes, [int]$Start, [int]$Length)
            for ($o = 0; $o + 4 -le $Length; $o += 4) {
                $single = [System.BitConverter]::ToSingle($Bytes, $Start + $o)
                [pscustomobject]@{
                    PSTypeName = 'NCLog.Word'
                    Offset     = $o
                    Hex        = [System.Convert]::ToHexString($Bytes, $Start + $o, 4)
                    Int32      = [System.BitConverter]::ToInt32($Bytes, $Start + $o)
                    Single     = $single
                }
            }
        }
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
            foreach ($p in $LiteralPath) { Resolve-NCLogPath -Cmdlet $PSCmdlet -InputPath $p -Literal }
        }
        else {
            foreach ($p in $Path) { Resolve-NCLogPath -Cmdlet $PSCmdlet -InputPath $p }
        }

        foreach ($file in $targets) {
            $stream = $null
            try {
                $stream = Open-NCLogFile -LiteralFilePath $file
                $length = $stream.Length

                $headerLength = [int][Math]::Min($HeaderSize, $length)
                $header = [byte[]]::new($headerLength)
                if ($headerLength -gt 0) {
                    Read-NCLogBlock -Stream $stream -Buffer $header -Count $headerLength
                }

                $body = [Math]::Max(0L, $length - $HeaderSize)
                $recordCount = [long][Math]::Floor($body / $RecordSize)
                $sampleRecords = [int][Math]::Min($SampleCount, $recordCount)

                $samples = [System.Collections.Generic.List[object]]::new()
                if ($sampleRecords -gt 0) {
                    $data = [byte[]]::new($sampleRecords * $RecordSize)
                    Read-NCLogBlock -Stream $stream -Buffer $data -Count $data.Length
                    for ($r = 0; $r -lt $sampleRecords; $r++) {
                        $start = $r * $RecordSize
                        $samples.Add([pscustomobject]@{
                                PSTypeName   = 'NCLog.Sample'
                                RecordNumber = $r
                                FileOffset   = [long]$HeaderSize + $start
                                Hex          = [System.Convert]::ToHexString($data, $start, $RecordSize)
                                Words        = @(ConvertTo-NCLogWord -Bytes $data -Start $start -Length $RecordSize)
                            })
                    }
                }

                [pscustomobject]@{
                    PSTypeName    = 'NCLog.FileInfo'
                    Path          = $file
                    Length        = $length
                    HeaderSize    = $HeaderSize
                    RecordSize    = $RecordSize
                    RecordCount   = $recordCount
                    TrailingBytes = $body % $RecordSize
                    HeaderHex     = [System.Convert]::ToHexString($header)
                    HeaderWords   = @(ConvertTo-NCLogWord -Bytes $header -Start 0 -Length $headerLength)
                    Samples       = $samples.ToArray()
                }
            }
            catch [System.IO.IOException], [System.UnauthorizedAccessException], [System.Security.SecurityException] {
                $PSCmdlet.WriteError((New-NCLogErrorRecord -Exception $_.Exception -ErrorId 'NCLogReadFailed' `
                            -Category ReadError -TargetObject $file))
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
    }
}
