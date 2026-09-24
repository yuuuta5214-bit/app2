#Requires -Version 7.2

<#
.SYNOPSIS
    NCLogTools の Pester テストを実行する。

.DESCRIPTION
    tests/*.Tests.ps1 を Pester 5 で実行します。
    -CI 指定時はテスト結果 (NUnit XML) とコードカバレッジ (JaCoCo XML) を
    TestResults フォルダに出力し、失敗があれば終了コード 1 で終了します。

    Pester 5.5 以上が必要です。Windows PowerShell 同梱の Pester 3.4 では動きません:
        Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck

.PARAMETER CI
    結果ファイルを出力し、失敗時に終了コード 1 で終了します。

.PARAMETER CodeCoverage
    コードカバレッジを計測します (-CI 指定時は常に有効)。

.PARAMETER MinimumCoverage
    カバレッジの下限 (%)。下回った場合は失敗扱いにします。既定 80。

.PARAMETER Output
    Pester の出力の詳しさ: None / Normal / Detailed / Diagnostic。既定 Detailed。

.PARAMETER TagFilter
    指定したタグのテストのみ実行します。

.EXAMPLE
    ./build/Invoke-NCLogToolsTest.ps1

    全テストを実行し、結果を詳細表示します。

.EXAMPLE
    ./build/Invoke-NCLogToolsTest.ps1 -CI

    CI 用に結果ファイルとカバレッジを出力します。
#>
[CmdletBinding()]
param(
    [switch]$CI,

    [switch]$CodeCoverage,

    [ValidateRange(0, 100)]
    [double]$MinimumCoverage = 80,

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed',

    [string[]]$TagFilter
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object Version -GE ([version]'5.5.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    throw 'Pester 5.5.0 以上が見つかりません。Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck を実行してください。'
}
Import-Module $pester -Force

$root = Split-Path -Path $PSScriptRoot -Parent
$resultsDir = Join-Path $root 'TestResults'

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = $Output
if ($TagFilter) { $config.Filter.Tag = $TagFilter }

if ($CI -or $CodeCoverage) {
    $null = New-Item -ItemType Directory -Path $resultsDir -Force
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @(
        Join-Path $root 'NCLogTools' 'Public'
        Join-Path $root 'NCLogTools' 'Private'
    )
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
    $config.CodeCoverage.OutputPath = Join-Path $resultsDir 'coverage.xml'
}
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $resultsDir 'testResults.xml'
}

Write-Host "Pester $($pester.Version) / PowerShell $($PSVersionTable.PSVersion) / $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
$result = Invoke-Pester -Configuration $config

$failed = $result.FailedCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or $result.FailedContainersCount -gt 0

if ($null -ne $result.CodeCoverage) {
    $coverage = [Math]::Round($result.CodeCoverage.CoveragePercent, 2)
    Write-Host "コードカバレッジ: $coverage % (下限 $MinimumCoverage %)"
    if ($coverage -lt $MinimumCoverage) {
        Write-Warning "コードカバレッジが下限を下回りました。"
        $failed = $true
    }
}

if ($CI) {
    exit ([int]$failed)
}
if ($failed) {
    Write-Error 'テストが失敗しました。' -ErrorAction Continue
}
