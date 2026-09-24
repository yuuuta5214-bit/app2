#Requires -Version 7.2
<#
    NCLogTools ルートモジュール
    Private/*.ps1 と Public/*.ps1 を読み込み、Public の関数のみを公開する。
#>
Set-StrictMode -Version 3.0

$private = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File -ErrorAction Stop)
$public = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File -ErrorAction Stop)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "NCLogTools: '$($file.FullName)' の読み込みに失敗しました: $_"
    }
}

Export-ModuleMember -Function $public.BaseName
