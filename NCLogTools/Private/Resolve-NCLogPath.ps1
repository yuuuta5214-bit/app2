function Resolve-NCLogPath {
    <#
    .SYNOPSIS
        PowerShell のパス (ワイルドカード・相対パス・PSDrive) を実ファイルの絶対パスへ解決する。
    .DESCRIPTION
        .NET の API は PowerShell の $PWD ではなくプロセスのカレントディレクトリを基準にするため、
        ファイルを開く前に必ずこの関数で絶対パスへ変換する。
        解決できないパスは呼び出し元コマンドの非終了エラーとして報告する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$InputPath,
        [switch]$Literal
    )

    # 例外に頼らず先に存在確認する。catch した例外でも呼び出し元の -ErrorVariable に
    # 記録されてしまうため (関数の階層ごとに重複する)、通常の「見つからない」は例外を発生させない。
    # Test-Path はワイルドカード不一致・存在しないドライブでも $false を返すだけでエラーを出さない。
    $exists = if ($Literal) { Test-Path -LiteralPath $InputPath } else { Test-Path -Path $InputPath }
    if (-not $exists) {
        $Cmdlet.WriteError((New-NCLogErrorRecord `
                    -Exception ([System.Management.Automation.ItemNotFoundException]::new("パスが見つかりません: $InputPath")) `
                    -ErrorId 'PathNotFound' -Category ObjectNotFound -TargetObject $InputPath))
        return
    }

    $provider = $null
    $drive = $null
    try {
        if ($Literal) {
            $resolved = @($Cmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
                    $InputPath, [ref]$provider, [ref]$drive))
        }
        else {
            $resolved = @($Cmdlet.SessionState.Path.GetResolvedProviderPathFromPSPath(
                    $InputPath, [ref]$provider))
        }
    }
    catch {
        # 確認後に削除された等の競合時のみここに来る。
        # .NET メソッド呼び出しの例外は MethodInvocationException に包まれるため、内側の例外で判定する
        $inner = $_.Exception
        while ($inner -is [System.Management.Automation.MethodInvocationException] -and $null -ne $inner.InnerException) {
            $inner = $inner.InnerException
        }
        $errorId = switch ($inner) {
            { $_ -is [System.Management.Automation.ItemNotFoundException] } { 'PathNotFound'; break }
            { $_ -is [System.Management.Automation.DriveNotFoundException] } { 'DriveNotFound'; break }
            { $_ -is [System.Management.Automation.ProviderNotFoundException] } { 'ProviderNotFound'; break }
            default { 'InvalidPath' }
        }
        $category = if ($errorId -eq 'InvalidPath') { 'InvalidArgument' } else { 'ObjectNotFound' }
        $Cmdlet.WriteError((New-NCLogErrorRecord -Exception $inner -ErrorId $errorId `
                    -Category $category -TargetObject $InputPath))
        return
    }

    if ($resolved.Count -eq 0) {
        # 確認後にファイルが消えた場合 (ワイルドカード一致なし) は、例外ではなく空が返る
        $Cmdlet.WriteError((New-NCLogErrorRecord `
                    -Exception ([System.Management.Automation.ItemNotFoundException]::new("一致するファイルがありません: $InputPath")) `
                    -ErrorId 'PathNotFound' -Category ObjectNotFound -TargetObject $InputPath))
        return
    }

    if ($provider.Name -ne 'FileSystem') {
        $Cmdlet.WriteError((New-NCLogErrorRecord `
                    -Exception ([System.ArgumentException]::new("ファイルシステムのパスではありません: $InputPath")) `
                    -ErrorId 'NotFileSystemPath' -Category InvalidArgument -TargetObject $InputPath))
        return
    }

    foreach ($item in $resolved) {
        if ([System.IO.File]::Exists($item)) {
            $item
        }
        else {
            $Cmdlet.WriteError((New-NCLogErrorRecord `
                        -Exception ([System.IO.FileNotFoundException]::new("ファイルが見つからないか、ディレクトリです: $item", $item)) `
                        -ErrorId 'FileNotFound' -Category ObjectNotFound -TargetObject $item))
        }
    }
}
