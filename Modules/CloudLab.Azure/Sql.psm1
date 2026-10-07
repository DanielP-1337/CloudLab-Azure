$ErrorActionPreference = 'Stop'
function Invoke-CLWindowsScript {
    param($Config,[string]$ProjectRoot,[string]$ScriptName,[string]$VM)
    $script = Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Windows/Common.ps1" Windows
    if ($ScriptName -eq 'Install-Application.ps1' -and $Config.App.ContainsKey('Provider') -and $Config.App.Provider -eq 'InfrastructureHealth') {
        $script += "`nfunction Install-CLHealthApplication {`n" + (Get-Content -Raw "$ProjectRoot/Scripts/Windows/Install-HealthApplication.ps1") + "`n}`n"
    }
    if ($ScriptName -eq 'Install-Sql.ps1') {
        $script += "`n" + (Get-Content -Raw "$ProjectRoot/Scripts/Windows/SqlDeveloperMedia.ps1")
    }
    $script += "`n" + (Get-Content -Raw "$ProjectRoot/Scripts/Windows/$ScriptName")
    Invoke-CLGuest $Config $VM $script Windows
}
function Deploy-CLSql {
    param($Config,[string]$ProjectRoot)
    if ($Config.Sql.ContainsKey('MediaProvider') -and $Config.Sql.MediaProvider -eq 'Developer2022') {
        if ($Config.Environment -ne 'sandbox' -or $Config.Sql.MajorVersion -ne 16) { throw 'Developer media requires sandbox and SQL major version 16.' }
        . "$ProjectRoot/Scripts/Windows/SqlDeveloperMedia.ps1"
        $lockPath = Join-Path $ProjectRoot '.local/releases/sql-developer.json'
        if (-not (Test-Path -LiteralPath $lockPath)) { throw 'Run Scripts/Prepare-SqlDeveloperMedia.ps1 locally first.' }
        $media = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
        Assert-CLSqlMediaLock $media
        $Config.Sql.DeveloperMedia = $media
    } elseif (-not $Config.Sql.ContainsKey('MediaProvider') -or $Config.Sql.MediaProvider -eq 'Staged') {
        Assert-CLValue $Config.Sql.SetupSha256 'Sql.SetupSha256' '^[a-fA-F0-9]{64}$'
    } else { throw 'Use Sql.MediaProvider Staged or Developer2022.' }
    Assert-CLValue $Config.Sql.Collation 'Sql.Collation' '^[A-Za-z0-9_]+$'
    Invoke-CLWindowsScript $Config $ProjectRoot 'Install-Sql.ps1' $Config.Sql.Name
}
function Deploy-CLApplication {
    param($Config,[string]$ProjectRoot)
    if ($Config.App.ContainsKey('Provider') -and $Config.App.Provider -eq 'InfrastructureHealth') {
        Import-Module "$ProjectRoot/Modules/CloudLab.Azure/HealthRelease.psm1" -Force
        $lockPath = Join-Path $ProjectRoot '.local/releases/health-release.json'
        if (-not (Test-Path -LiteralPath $lockPath)) { throw 'Run Scripts/Prepare-HealthRelease.ps1 before deployment.' }
        $release = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
        Assert-CLHealthRelease $release
        if ($Config.App.HealthPath -ne '/App/health/') { throw 'Set App.HealthPath to /App/health/.' }
        if (@($Config.App.WriterServices).Count -ne 0) { throw 'The generic health app has no writer services. Set App.WriterServices to @().' }
        $Config.App.HealthRelease = $release
    } elseif (-not $Config.App.ContainsKey('Provider') -or $Config.App.Provider -eq 'Custom') {
        Assert-CLValue $Config.App.InstallerSha256 'App.InstallerSha256' '^[a-fA-F0-9]{64}$'
    } else { throw 'Unknown App.Provider. Use Custom or InfrastructureHealth.' }
    Invoke-CLWindowsScript $Config $ProjectRoot 'Install-Application.ps1' $Config.App.Name
}
Export-ModuleMember -Function *-CL*
