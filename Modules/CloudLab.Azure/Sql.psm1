$ErrorActionPreference = 'Stop'
function Invoke-CLWindowsScript {
    param($Config,[string]$ProjectRoot,[string]$ScriptName,[string]$VM)
    $script = Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Windows/Common.ps1" Windows
    $script += "`n" + (Get-Content -Raw "$ProjectRoot/Scripts/Windows/$ScriptName")
    Invoke-CLGuest $Config $VM $script Windows
}
function Deploy-CLSql {
    param($Config,[string]$ProjectRoot)
    Assert-CLValue $Config.Sql.SetupSha256 'Sql.SetupSha256' '^[a-fA-F0-9]{64}$'
    Assert-CLValue $Config.Sql.Collation 'Sql.Collation' '^[A-Za-z0-9_]+$'
    Invoke-CLWindowsScript $Config $ProjectRoot 'Install-Sql.ps1' $Config.Sql.Name
}
function Deploy-CLApplication {
    param($Config,[string]$ProjectRoot)
    Assert-CLValue $Config.App.InstallerSha256 'App.InstallerSha256' '^[a-fA-F0-9]{64}$'
    Invoke-CLWindowsScript $Config $ProjectRoot 'Install-Application.ps1' $Config.App.Name
}
Export-ModuleMember -Function *-CL*
