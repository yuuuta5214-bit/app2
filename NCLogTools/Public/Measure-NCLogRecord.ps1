function Measure-NCLogRecord {
    <#
    .SYNOPSIS
        NCLog.Record の統計情報 (件数・最小・最大・平均・標準偏差) を計算する。

    .DESCRIPTION
        Get-NCLogRecord の出力を受け取り、ADD_40_0 (Value40) と ADD_21_0 (Value21) それぞれの
        統計を NCLog.Statistic オブジェクトとして出力します。

        Welford 法による1パス計算のため、全件をメモリに保持せず、数値的にも安定しています。
        StdDev は母標準偏差 (n で割る)、SampleStdDev は標本標準偏差 (n-1 で割る) です。

    .PARAMETER InputObject
        NCLog.Record オブジェクト (Get-NCLogRecord の出力)。

    .PARAMETER GroupBy
        'File' (既定): ファイルごとに集計します。
        'None'       : 全ファイルをまとめて集計します (SourceFile は '*')。

    .INPUTS
        NCLog.Record

    .OUTPUTS
        NCLog.Statistic

    .EXAMPLE
        Get-NCLogRecord 'C:\Logs\NCLog_*.BIN' | Measure-NCLogRecord

        ファイルごと・パラメーターごとの統計を取得します。

    .EXAMPLE
        Get-NCLogRecord 'C:\Logs\NCLog_*.BIN' -HideZeros | Measure-NCLogRecord -GroupBy None |
            Where-Object Parameter -eq 'ADD_40_0'

        全ファイル合算のレーザー出力の統計を取得します。

    .LINK
        Get-NCLogRecord
    #>
    [CmdletBinding()]
    [OutputType('NCLog.Statistic')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSTypeName('NCLog.Record')]
        [psobject]$InputObject,

        [ValidateSet('File', 'None')]
        [string]$GroupBy = 'File'
    )

    begin {
        $definitions = @(
            [pscustomobject]@{ Property = 'Value40'; Parameter = 'ADD_40_0'; Description = 'レーザー出力パワー'; Unit = '%' }
            [pscustomobject]@{ Property = 'Value21'; Parameter = 'ADD_21_0'; Description = 'ワイヤフィード速度'; Unit = 'mm/min' }
        )
        # キー: SourceFile / 値: Property 名ごとの累積状態 (挿入順を保持)
        $groups = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    process {
        $key = if ($GroupBy -eq 'File') { [string]$InputObject.SourceFile } else { '*' }

        $state = $groups[$key]
        if ($null -eq $state) {
            $state = @{}
            foreach ($def in $definitions) {
                $state[$def.Property] = @{
                    N    = 0L
                    Mean = 0.0
                    M2   = 0.0
                    Min  = [double]::PositiveInfinity
                    Max  = [double]::NegativeInfinity
                }
            }
            $groups[$key] = $state
        }

        foreach ($def in $definitions) {
            $x = [double]$InputObject.($def.Property)
            $s = $state[$def.Property]
            $s.N++
            $delta = $x - $s.Mean
            $s.Mean += $delta / $s.N
            $s.M2 += $delta * ($x - $s.Mean)
            if ($x -lt $s.Min) { $s.Min = $x }
            if ($x -gt $s.Max) { $s.Max = $x }
        }
    }

    end {
        foreach ($key in $groups.Keys) {
            foreach ($def in $definitions) {
                $s = $groups[$key][$def.Property]
                [pscustomobject]@{
                    PSTypeName   = 'NCLog.Statistic'
                    SourceFile   = $key
                    Parameter    = $def.Parameter
                    Description  = $def.Description
                    Unit         = $def.Unit
                    Count        = $s.N
                    Minimum      = $s.Min
                    Maximum      = $s.Max
                    Average      = $s.Mean
                    StdDev       = [Math]::Sqrt($s.M2 / $s.N)
                    SampleStdDev = if ($s.N -gt 1) { [Math]::Sqrt($s.M2 / ($s.N - 1)) } else { 0.0 }
                }
            }
        }
    }
}
