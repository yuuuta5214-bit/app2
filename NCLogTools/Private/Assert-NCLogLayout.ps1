function Assert-NCLogLayout {
    <#
    .SYNOPSIS
        レコードレイアウトと実行環境の前提を検証し、不正なら呼び出し元コマンドを終了させる。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][int]$RecordSize,
        [Parameter(Mandatory)][int]$Value40Offset,
        [Parameter(Mandatory)][int]$Value21Offset
    )

    # BitConverter は CPU のエンディアンで解釈する。Windows (x64/ARM64) は常にリトルエンディアン
    if (-not [System.BitConverter]::IsLittleEndian) {
        $Cmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                    -Exception ([System.PlatformNotSupportedException]::new('ビッグエンディアン環境はサポートしていません。')) `
                    -ErrorId 'BigEndianNotSupported' -Category NotImplemented -TargetObject $null))
    }

    # ADD_40_0 (UInt16 2 byte) / ADD_21_0 (Double 8 byte) がレコード内に重ならずに収まること
    $problem = Get-NCLogLayoutProblem -RecordSize $RecordSize -Value40Offset $Value40Offset -Value21Offset $Value21Offset
    if ($null -ne $problem) {
        $Cmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                    -Exception ([System.ArgumentOutOfRangeException]::new($problem.Name, $problem.Message)) `
                    -ErrorId 'InvalidRecordLayout' -Category InvalidArgument -TargetObject $problem.Name))
    }
}
