function New-NCLogErrorRecord {
    <#
    .SYNOPSIS
        ErrorRecord を生成する内部ヘルパー。
    .DESCRIPTION
        FullyQualifiedErrorId で原因を判別できるよう、ErrorId とカテゴリを必ず付与する。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'メモリ上に ErrorRecord を作るだけで、システムの状態は変更しない')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][System.Exception]$Exception,
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)][System.Management.Automation.ErrorCategory]$Category,
        [AllowNull()][object]$TargetObject
    )

    [System.Management.Automation.ErrorRecord]::new($Exception, $ErrorId, $Category, $TargetObject)
}
