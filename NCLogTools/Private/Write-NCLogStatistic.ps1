function Write-NCLogStatistic {
    <#
    .SYNOPSIS
        Measure-NCLogRecord の結果をホストに表示する (データ出力ストリームは汚さない)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Statistic
    )

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($group in ($Statistic | Group-Object -Property SourceFile)) {
        Write-Host ''
        Write-Host "📊 統計情報: $($group.Name)" -ForegroundColor Cyan
        Write-Host ('─' * 60) -ForegroundColor Cyan
        foreach ($stat in $group.Group) {
            Write-Host "$($stat.Parameter) ($($stat.Description) $($stat.Unit))"
            Write-Host ([string]::Format($ic, '  件数:      {0}', $stat.Count))
            Write-Host ([string]::Format($ic, '  最小:      {0:F6}', $stat.Minimum))
            Write-Host ([string]::Format($ic, '  最大:      {0:F6}', $stat.Maximum))
            Write-Host ([string]::Format($ic, '  平均:      {0:F6}', $stat.Average))
            Write-Host ([string]::Format($ic, '  標準偏差:  {0:F6}', $stat.StdDev))
            Write-Host ''
        }
    }
}
