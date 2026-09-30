function Invoke-NCLogBatchCsvExport {
    <#
    .SYNOPSIS
        複数の BIN をそれぞれ指定の CSV に出力する (ビューアーの一括 CSV 出力)。
    .DESCRIPTION
        Item ごとに Export-NCLogValue -Format CSV を呼び、結果を1件ずつ返す。
        1件が失敗しても残りは続ける。

        Item のプロパティ:
            SourcePath / OutputPath                          BIN と出力 CSV の絶対パス
            HeaderSize / RecordSize / Value40Offset / Value21Offset   解析に使うレイアウト
            ValidCount                                       有効レコード数 (0 なら出力しない)

        既存の CSV は ExistingAction が Overwrite なら上書き、Skip なら出力しない。
    .OUTPUTS
        [pscustomobject] SourcePath / OutputPath / Result (Exported / Skipped / Failed) / Message
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [ValidateSet('Overwrite', 'Skip')][string]$ExistingAction = 'Skip'
    )

    foreach ($i in $Item) {
        $result = [pscustomobject]@{
            SourcePath = $i.SourcePath
            OutputPath = $i.OutputPath
            Result     = 'Failed'
            Message    = ''
        }

        try {
            $name = [System.IO.Path]::GetFileName($i.OutputPath)
            if (-not [System.IO.Path]::IsPathRooted($i.OutputPath) -or [string]::IsNullOrEmpty($name) -or
                $name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw [System.ArgumentException]::new("出力先のパスが不正です: $($i.OutputPath)")
            }
            $folder = [System.IO.Path]::GetDirectoryName($i.OutputPath)
            if (-not [System.IO.Directory]::Exists($folder)) {
                throw [System.IO.DirectoryNotFoundException]::new("出力先フォルダが存在しません: $folder")
            }
            if ($i.ValidCount -le 0) {
                throw [System.InvalidOperationException]::new('有効なレコードがありません。')
            }

            $exists = [System.IO.File]::Exists($i.OutputPath)
            if ($exists -and $ExistingAction -eq 'Skip') {
                $result.Result = 'Skipped'
                $result.Message = '既に存在するため出力しませんでした。'
            }
            elseif ($PSCmdlet.ShouldProcess($i.OutputPath, "CSV に出力 ($($i.SourcePath))")) {
                $exportParams = @{
                    LiteralPath   = $i.SourcePath
                    Format        = 'CSV'
                    OutputPath    = $i.OutputPath
                    Force         = $exists
                    HeaderSize    = $i.HeaderSize
                    RecordSize    = $i.RecordSize
                    Value40Offset = $i.Value40Offset
                    Value21Offset = $i.Value21Offset
                    ErrorAction   = 'Stop'
                    WarningAction = 'SilentlyContinue'
                    Confirm       = $false
                }
                # Export-NCLogValue は完了メッセージを Write-Host で出すため、情報ストリームごと捨てる
                Export-NCLogValue @exportParams 6>$null
                $result.Result = 'Exported'
                $result.Message = "$($i.ValidCount) 件"
            }
            else {
                $result.Result = 'Skipped'
                $result.Message = 'WhatIf'
            }
        }
        catch {
            $ex = $_.Exception
            while ($ex -is [System.Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) {
                $ex = $ex.InnerException
            }
            $result.Result = 'Failed'
            $result.Message = $ex.Message
        }

        $result
    }
}
