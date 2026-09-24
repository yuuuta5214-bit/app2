#Requires -Version 7.2

<#
.SYNOPSIS
    NCLogExport.cmd を含む配布用 ZIP を作成する。

.DESCRIPTION
    利用者に必要なファイルだけを1つの ZIP にまとめます。

        NCLogTools-<version>\
          NCLogExport.cmd
          Export-NCLogValues.ps1
          README.md
          NCLogTools\ ...
          tools\ ...

    テキストファイルは Windows 向けに改行を CRLF に統一します
    (.cmd が LF 改行だと、cmd.exe のラベルジャンプが誤動作するため)。
    ZIP 内のパス区切りは '/' を使うため、どの OS で作成しても Windows で正しく展開できます。

.PARAMETER DestinationPath
    ZIP の出力先フォルダ。既定はリポジトリ直下の dist フォルダ。

.PARAMETER Force
    同名の ZIP があれば上書きします。

.OUTPUTS
    System.IO.FileInfo (作成した ZIP)

.EXAMPLE
    ./build/New-NCLogToolsPackage.ps1

    dist\NCLogTools-2.1.0.zip を作成します。
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.IO.FileInfo])]
param(
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'),

    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'NCLogTools' 'NCLogTools.psd1')).ModuleVersion
$packageName = "NCLogTools-$version"

$items = @(
    'NCLogExport.cmd'
    'Export-NCLogValues.ps1'
    'README.md'
    'NCLogTools'
    'tools'
)
$textExtensions = '.cmd', '.bat', '.ps1', '.psm1', '.psd1', '.ps1xml', '.md', '.txt'

$files = foreach ($item in $items) {
    $full = Join-Path $root $item
    if (-not (Test-Path -LiteralPath $full)) { throw "パッケージに必要なファイルがありません: $full" }
    if ((Get-Item -LiteralPath $full).PSIsContainer) {
        Get-ChildItem -LiteralPath $full -Recurse -File
    }
    else {
        Get-Item -LiteralPath $full
    }
}

$destination = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
$zipPath = Join-Path $destination "$packageName.zip"
if ((Test-Path -LiteralPath $zipPath) -and -not $Force) {
    throw "既に存在します。上書きするには -Force を指定してください: $zipPath"
}

if (-not $PSCmdlet.ShouldProcess($zipPath, "$($files.Count) ファイルをパッケージ化")) { return }

$null = New-Item -ItemType Directory -Path $destination -Force
Add-Type -AssemblyName System.IO.Compression
$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
try {
    $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $relative = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
            $entry = $zip.CreateEntry("$packageName/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $file.LastWriteTime
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

            if ($file.Extension.ToLowerInvariant() -in $textExtensions) {
                # BOM は保持したまま、改行だけ CRLF に揃える (UTF-8 / ASCII 前提)
                $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                $text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            }

            $entryStream = $entry.Open()
            try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
    }
}
finally {
    $stream.Dispose()
}

Get-Item -LiteralPath $zipPath
