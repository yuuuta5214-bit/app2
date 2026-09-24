#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'NCLogTools' 'NCLogTools.psd1') -Force

    function New-Record {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'テスト用オブジェクトを作るだけ')]
        param([string]$File, [double]$V40, [double]$V21)
        [pscustomobject]@{
            PSTypeName   = 'NCLog.Record'
            SourceFile   = $File
            RecordNumber = 0L
            Value40      = [single]$V40
            Value21      = [single]$V21
        }
    }
}

AfterAll {
    Remove-Module NCLogTools -Force -ErrorAction SilentlyContinue
}

Describe 'Measure-NCLogRecord' {

    It '既知のデータで件数・最小・最大・平均・標準偏差が正しい' {
        # 2,4,4,4,5,5,7,9 : 平均 5 / 母標準偏差 2 / 標本標準偏差 sqrt(32/7)
        $values = 2, 4, 4, 4, 5, 5, 7, 9
        $stats = $values | ForEach-Object { New-Record -File 'a.BIN' -V40 $_ -V21 ($_ * 100) } | Measure-NCLogRecord
        $s40 = $stats | Where-Object Parameter -EQ 'ADD_40_0'
        $s21 = $stats | Where-Object Parameter -EQ 'ADD_21_0'

        $s40.Count | Should -Be 8
        $s40.Minimum | Should -Be 2
        $s40.Maximum | Should -Be 9
        $s40.Average | Should -Be 5
        $s40.StdDev | Should -BeLessThan 2.0000001
        $s40.StdDev | Should -BeGreaterThan 1.9999999
        [Math]::Abs($s40.SampleStdDev - [Math]::Sqrt(32 / 7)) | Should -BeLessThan 1e-9

        $s21.Average | Should -Be 500
        $s21.Unit | Should -Be 'mm/min'
        $s40.PSObject.TypeNames | Should -Contain 'NCLog.Statistic'
    }

    It '1件だけなら標準偏差は 0' {
        $s = New-Record -File 'a.BIN' -V40 7 -V21 70 | Measure-NCLogRecord
        $s.StdDev | Should -Be @(0, 0)
        $s.SampleStdDev | Should -Be @(0, 0)
    }

    It '既定ではファイルごと、入力順に集計する' {
        $stats = @(
            New-Record -File 'b.BIN' -V40 1 -V21 10
            New-Record -File 'a.BIN' -V40 3 -V21 30
            New-Record -File 'b.BIN' -V40 5 -V21 50
        ) | Measure-NCLogRecord
        $stats.Count | Should -Be 4
        $stats[0].SourceFile | Should -Be 'b.BIN'
        ($stats | Where-Object { $_.SourceFile -eq 'b.BIN' -and $_.Parameter -eq 'ADD_40_0' }).Average | Should -Be 3
    }

    It "-GroupBy None は全体を1グループ ('*') で集計する" {
        $stats = @(
            New-Record -File 'a.BIN' -V40 1 -V21 10
            New-Record -File 'b.BIN' -V40 3 -V21 30
        ) | Measure-NCLogRecord -GroupBy None
        $stats.Count | Should -Be 2
        $stats[0].SourceFile | Should -Be '*'
        $stats[0].Count | Should -Be 2
    }

    It '入力がなければ何も出力しない' {
        @(@() | Measure-NCLogRecord).Count | Should -Be 0
    }

    It 'NCLog.Record 以外の入力は拒否する' {
        { [pscustomobject]@{ Value40 = 1; Value21 = 2 } | Measure-NCLogRecord -ErrorAction Stop } |
            Should -Throw -ErrorId 'InputObjectNotBound,Measure-NCLogRecord'
    }

    It '大きな値でも数値的に安定している (Welford 法)' {
        $stats = (1e6 + 1), (1e6 + 2), (1e6 + 3) | ForEach-Object { New-Record -File 'a.BIN' -V40 1 -V21 $_ } |
            Measure-NCLogRecord | Where-Object Parameter -EQ 'ADD_21_0'
        [Math]::Abs($stats.StdDev - [Math]::Sqrt(2 / 3)) | Should -BeLessThan 1e-6
    }
}
