function Resolve-NCLogViewerLayout {
    <#
    .SYNOPSIS
        ビューアーで入力されたレイアウト (文字列) を検証し、数値のレイアウトに変換する。
    .DESCRIPTION
        範囲は Get-NCLogRecord のパラメーター検証と同じ。
        不正な場合は、画面にそのまま表示できる日本語メッセージで ArgumentException / FormatException。
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HeaderSize,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RecordSize,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value40Offset,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value21Offset
    )

    $layout = @{}
    foreach ($item in @(
            @{ Name = 'HeaderSize'; Label = 'ヘッダーサイズ'; Text = $HeaderSize; Min = 0; Max = 1MB }
            @{ Name = 'RecordSize'; Label = 'レコードサイズ'; Text = $RecordSize; Min = 8; Max = 64KB }
            @{ Name = 'Value40Offset'; Label = 'ADD_40_0 のオフセット'; Text = $Value40Offset; Min = 0; Max = 64KB }
            @{ Name = 'Value21Offset'; Label = 'ADD_21_0 のオフセット'; Text = $Value21Offset; Min = 0; Max = 64KB }
        )) {
        $value = ConvertFrom-NCLogNumberText -Text $item.Text -Name $item.Label
        if ($value -lt $item.Min -or $value -gt $item.Max) {
            throw [System.ArgumentException]::new("$($item.Label) は $($item.Min) ～ $($item.Max) の範囲で指定してください: $value")
        }
        $layout[$item.Name] = [int]$value
    }

    $problem = Get-NCLogLayoutProblem -RecordSize $layout.RecordSize -Value40Offset $layout.Value40Offset `
        -Value21Offset $layout.Value21Offset
    if ($null -ne $problem) {
        throw [System.ArgumentException]::new($problem.Message)
    }

    $layout
}
