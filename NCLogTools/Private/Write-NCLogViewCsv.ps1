function Write-NCLogViewCsv {
    <#
    .SYNOPSIS
        BIN を解析して CSV に書く (ビューアーの CSV 出力用の高速版)。書いた件数を返す。
    .DESCRIPTION
        内容は Export-NCLogValue -Format CSV と同じ (UTF-8 BOM 付き、有効レコードのみ):
            "SourceFile","RecordNumber","Value40","Value21"

        Export-NCLogValue は 1 レコードごとにオブジェクトを作ってすべてメモリに溜めるため、
        100 万レコードで約 35 秒・2GB を使い、複数ファイルの一括出力では PC が固まる。
        この関数は解析結果の配列から直接ファイルに書く (C# 版で 1 秒未満、メモリは配列分のみ)。

        既存のファイルは Force がなければ上書きしない (FileMode.CreateNew で作成し、確認と作成の間の競合も防ぐ)。
        書き込みの途中で失敗した場合は、作りかけのファイルを削除する。
    .PARAMETER Layout
        HeaderSize / RecordSize / Value40Offset / Value21Offset を持つ hashtable。
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][hashtable]$Layout,
        [switch]$Force
    )

    $data = Read-NCLogViewerFileData -LiteralFilePath $SourcePath -Layout $Layout
    $mode = if ($Force) { [System.IO.FileMode]::Create } else { [System.IO.FileMode]::CreateNew }

    $stream = [System.IO.FileStream]::new($OutputPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $completed = $false
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($true))
        try {
            if (Test-NCLogNative) {
                $written = [NCLogToolsNative.V1.RecordDecoder]::WriteCsv($writer, $SourcePath, $data.Value40, $data.Value21, $data.Valid)
            }
            else {
                # PowerShell 版 (C# が使えない環境用。結果は同じ)
                $ic = [System.Globalization.CultureInfo]::InvariantCulture
                $source = '"' + $SourcePath.Replace('"', '""') + '","'
                $writer.WriteLine('"SourceFile","RecordNumber","Value40","Value21"')
                $written = 0
                $v40 = $data.Value40
                $v21 = $data.Value21
                $valid = $data.Valid
                for ($i = 0; $i -lt $valid.Length; $i++) {
                    if (-not $valid[$i]) { continue }
                    $writer.WriteLine($source + $i.ToString($ic) + '","' + $v40[$i].ToString($ic) + '","' + $v21[$i].ToString($ic) + '"')
                    $written++
                }
            }
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
        $completed = $true
    }
    finally {
        $stream.Dispose()
        if (-not $completed) {
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        }
    }
    $written
}
