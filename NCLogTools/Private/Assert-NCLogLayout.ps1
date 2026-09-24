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

    foreach ($entry in @(
            @{ Name = 'Value40Offset'; Value = $Value40Offset }
            @{ Name = 'Value21Offset'; Value = $Value21Offset }
        )) {
        if ($entry.Value + 4 -gt $RecordSize) {
            $Cmdlet.ThrowTerminatingError((New-NCLogErrorRecord `
                        -Exception ([System.ArgumentOutOfRangeException]::new($entry.Name,
                            "$($entry.Name) ($($entry.Value)) + 4 byte がレコードサイズ $RecordSize を超えています。")) `
                        -ErrorId 'InvalidRecordLayout' -Category InvalidArgument -TargetObject $entry.Value))
        }
    }
}
