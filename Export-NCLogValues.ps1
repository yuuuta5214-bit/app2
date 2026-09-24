#Requires -Version 7.2

<#
.SYNOPSIS
    NCログ (.BIN) から ADD_40_0 と ADD_21_0 を抽出するCLIツール (互換ラッパー)

.DESCRIPTION
    v2.1 から処理本体は NCLogTools モジュール (./NCLogTools) に移りました。
    このスクリプトは既存の呼び出し方 (.\Export-NCLogValues.ps1 -FilePath ...) を
    維持するための薄いラッパーで、同じフォルダの NCLogTools を読み込み、
    すべての引数とパイプライン入力を Export-NCLogValue にそのまま渡します。

    新規利用ではモジュールを直接使うことを推奨します:
        Import-Module .\NCLogTools
        Get-Help Export-NCLogValue -Full

    - ADD_40_0: amPrcLg_output_pwr (実レーザー出力パワー %)
    - ADD_21_0: realWirFeed_vel    (実ワイヤフィード速度 mm/min)

.PARAMETER Path
    NCログバイナリファイルのパス。ワイルドカード可。別名: FilePath

.PARAMETER LiteralPath
    ワイルドカードとして解釈しないパス。

.PARAMETER OutputPath
    出力ファイルのパス。省略時はパイプライン (画面) に出力します。

.PARAMETER Format
    出力形式: 'Table'(既定), 'CSV', 'TSV', 'JSON', 'Raw'

.PARAMETER Statistics
    統計情報をファイルごとに表示します。

.PARAMETER HideZeros
    ADD_40_0 と ADD_21_0 が両方 0 のレコードを除外します。

.PARAMETER MaxRecords
    出力する最大レコード数 (全ファイル合計)。

.PARAMETER AsObject
    PowerShell オブジェクトを返します。

.PARAMETER Force
    既存の OutputPath を上書きします。

.PARAMETER Encoding
    出力ファイルの文字コード。既定 utf8BOM。

.PARAMETER HeaderSize
    ヘッダーのバイト数。既定 0x20。

.PARAMETER RecordSize
    1レコードのバイト数。既定 16。

.PARAMETER Value40Offset
    レコード内の ADD_40_0 のオフセット。既定 4。

.PARAMETER Value21Offset
    レコード内の ADD_21_0 のオフセット。既定 8。

.EXAMPLE
    .\Export-NCLogValues.ps1 -FilePath 'NCLog_00000000_00003044.BIN'

.EXAMPLE
    .\Export-NCLogValues.ps1 -Path 'C:\Logs\NCLog_*.BIN' -OutputPath 'output.csv' -Format CSV -Statistics

.EXAMPLE
    Get-ChildItem 'C:\Logs' -Filter 'NCLog*.BIN' |
        .\Export-NCLogValues.ps1 -OutputPath 'combined.json' -Format JSON -Force

.NOTES
    バージョン: 2.1
    詳細なヘルプ: Get-Help Export-NCLogValue -Full (NCLogTools 読み込み後)
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
    # 同じフォルダのモジュールだけを明示パスで読み込む (PSModulePath 上の同名モジュールを誤って使わない)
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath 'NCLogTools' -AdditionalChildPath 'NCLogTools.psd1'
    try {
        $module = Import-Module -Name $manifest -PassThru -ErrorAction Stop

        # 引数・パイプライン入力・-WhatIf などの共通パラメーターをそのまま渡すプロキシ
        $target = $module.ExportedFunctions['Export-NCLogValue']
        $forwarded = $PSBoundParameters
        $steppable = { & $target @forwarded }.GetSteppablePipeline($MyInvocation.CommandOrigin)
    }
    catch {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                $_.Exception, 'NCLogToolsLoadFailed',
                [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $manifest))
    }
    $steppable.Begin($PSCmdlet)
}

process {
    if ($MyInvocation.ExpectingInput) {
        $steppable.Process($_)
    }
    else {
        $steppable.Process()
    }
}

end {
    $steppable.End()
}
