@{
    RootModule           = 'NCLogTools.psm1'
    ModuleVersion        = '2.1.0'
    GUID                 = '6f1d3c7e-2b9a-4c55-9e0d-8a7f4b1e3c21'
    Author               = 'yuuuta5214-bit'
    Copyright            = '(c) yuuuta5214-bit. All rights reserved.'
    Description          = 'ワイヤレーザー3Dプリンターの NCLog バイナリ (.BIN) から ADD_40_0 (レーザー出力) と ADD_21_0 (ワイヤフィード速度) を抽出・集計・出力するツール'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FormatsToProcess     = @('NCLogTools.Format.ps1xml')
    FunctionsToExport    = @(
        'Export-NCLogValue'
        'Get-NCLogFileInfo'
        'Get-NCLogRecord'
        'Measure-NCLogRecord'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('NCLog', 'LaserMetalDeposition', 'WireLaser', 'Binary', 'Windows')
            ReleaseNotes = 'v2.1.0: モジュール化、Get-NCLogFileInfo / Measure-NCLogRecord 追加、Pester テスト追加'
        }
    }
}
