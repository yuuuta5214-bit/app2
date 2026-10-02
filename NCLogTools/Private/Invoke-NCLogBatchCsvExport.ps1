function Invoke-NCLogBatchCsvExport {
    <#
    .SYNOPSIS
        複数の BIN をそれぞれ指定の CSV に出力する (ビューアーの一括 CSV 出力)。
    .DESCRIPTION
        Item ごとに Write-NCLogViewCsv で CSV を書き (内容は Export-NCLogValue -Format CSV と同じ)、
        結果を1件ずつ返す。1件が失敗しても残りは続ける。

        Item のプロパティ:
            SourcePath / OutputPath                          BIN と出力 CSV の絶対パス
            HeaderSize / RecordSize / Value40Offset / Value21Offset   解析に使うレイアウト
            ValidCount                                       有効レコード数 (0 なら出力しない)

        既存の CSV は ExistingAction が Overwrite なら上書き、Skip なら出力しない。
        OnProgress を指定すると、各ファイルの処理前に (番号, 件数, Item) を渡して呼ぶ (画面の進捗表示用)。
    .OUTPUTS
        [pscustomobject] SourcePath / OutputPath / Result (Exported / Skipped / Failed) / Message
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [ValidateSet('Overwrite', 'Skip')][string]$ExistingAction = 'Skip',
        [scriptblock]$OnProgress
    )

    $number = 0
    foreach ($i in $Item) {
        $number++
        if ($OnProgress) { & $OnProgress $number $Item.Count $i }
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
                $layout = @{
                    HeaderSize    = [int]$i.HeaderSize
                    RecordSize    = [int]$i.RecordSize
                    Value40Offset = [int]$i.Value40Offset
                    Value21Offset = [int]$i.Value21Offset
                }
                $written = Write-NCLogViewCsv -SourcePath $i.SourcePath -OutputPath $i.OutputPath -Layout $layout -Force:$exists
                $result.Result = 'Exported'
                $result.Message = "$written 件"
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
