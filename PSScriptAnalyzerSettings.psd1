@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # 統計の色付き表示と保存完了メッセージは意図的にホストへ出力している
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.2')
        }
    }
}
