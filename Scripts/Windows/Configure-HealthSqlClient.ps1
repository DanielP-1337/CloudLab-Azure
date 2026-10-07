# Runs as LocalSystem on the application VM, after health release installation.
$h=$CL.HealthSql
$install=Join-Path $env:ProgramData 'InfrastructureHealthBenchmark'
if ((Get-Content -Raw "$install/VERSION").Trim() -ne '0.1.8') { throw 'This adapter is reviewed for health release 0.1.8 only.' }
if ((Get-Content -Raw (Join-Path $CL.App.SitePath '.cloudlab-health-owner')).Trim() -ne $CL.ProjectId) { throw 'Health site project mismatch.' }
$taskName='Infrastructure Health & Benchmark Diagnostics'
$task=Get-ScheduledTask -TaskName $taskName
if ($task.Principal.UserId -notin @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')) { throw 'The health task must run as LocalSystem.' }
$dir=Join-Path $env:ProgramData 'CloudLab/HealthSql'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect SQL adapter state.' }
$taskState=Join-Path $dir 'task-state.json'
if (Test-Path -LiteralPath $taskState) {
    $saved=Get-Content -Raw $taskState | ConvertFrom-Json
    if ($saved.ProjectId -ne $CL.ProjectId) { throw 'Task state project mismatch.' }
    $wasEnabled=[bool]$saved.Enabled
} else {
    $wasEnabled=$task.State -ne 'Disabled'
    @{ProjectId=$CL.ProjectId;Enabled=$wasEnabled} | ConvertTo-Json | Set-Content $taskState -Encoding utf8
}
Disable-ScheduledTask -TaskName $taskName | Out-Null
Stop-ScheduledTask -TaskName $taskName
$deadline=(Get-Date).AddSeconds(30)
while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
    if ((Get-Date) -gt $deadline) { throw 'Health task did not stop.' }
    Start-Sleep -Milliseconds 250
}
# Keep task disabled on failure; never restore a partially configured SQL probe.
$dir=Join-Path $env:ProgramData 'CloudLab/HealthSql'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$rootCert=New-Object Security.Cryptography.X509Certificates.X509Certificate2
$rootCert.Import([Convert]::FromBase64String($h.RootDerBase64))
if ($rootCert.Thumbprint -ne $h.RootThumbprint) { throw 'SQL trust root mismatch.' }
$store=New-Object Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
try { $store.Open('ReadWrite');$store.Add($rootCert) } finally { $store.Close();$rootCert.Dispose() }
$driverName='ODBC Driver 18 for SQL Server'
$drivers=@(Get-OdbcDriver -Name $driverName -Platform '64-bit' -ErrorAction SilentlyContinue)
if (-not $drivers.Count) {
    $msi=Join-Path $dir 'msodbcsql.msi'
    Invoke-WebRequest -UseBasicParsing -Uri $h.Driver.Uri -OutFile $msi
    if ((Get-FileHash $msi -Algorithm SHA256).Hash -ne $h.Driver.Sha256) { throw 'ODBC MSI hash mismatch.' }
    Assert-CLMicrosoftBinary $msi
    $p=Start-Process msiexec.exe -ArgumentList @('/i',"`"$msi`"",'/qn','/norestart','IACCEPTMSODBCSQLLICENSETERMS=YES') -Wait -PassThru
    if ($p.ExitCode -eq 3010) { throw 'ODBC installed. Reboot app VM and rerun configuration; health task remains disabled.' }
    if ($p.ExitCode -ne 0) { throw 'ODBC installation failed.' }
}
foreach ($platform in '64-bit','32-bit') {
    $driver=Get-OdbcDriver -Name $driverName -Platform $platform -ErrorAction Stop
    if (-not $driver) { throw 'ODBC Driver 18 missing for an architecture.' }
    $view=if ($platform -eq '64-bit') { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    $reg=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
    $sub=$null
    try {
        $sub=$reg.OpenSubKey('SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server')
        $dll=[string]$sub.GetValue('Driver')
        $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
        if ($version.FileMajorPart -ne 18 -or $version.FileMinorPart -ne 7 -or $version.FileBuildPart -ne 1 -or $version.FilePrivatePart -ne 1) {
            throw 'Existing ODBC driver differs from 18.7.1.1. Review upgrade explicitly.'
        }
    } finally { if ($sub) { $sub.Dispose() };$reg.Dispose() }

}
$ownerFile=Join-Path $dir 'owner.txt'
$owned=Test-Path -LiteralPath $ownerFile
if ($owned -and (Get-Content -Raw $ownerFile).Trim() -ne $CL.ProjectId) { throw 'ODBC configuration belongs to another project.' }
foreach ($platform in '64-bit','32-bit') {
    $dsn=Get-OdbcDsn -Name HealthCheck -DsnType System -Platform $platform -ErrorAction SilentlyContinue
    if ($dsn -and -not $owned) { throw 'Refusing to adopt an existing HealthCheck DSN.' }
}
Set-Content -LiteralPath $ownerFile -Value $CL.ProjectId -Encoding ascii
foreach ($platform in '64-bit','32-bit') {
    $dsn=Get-OdbcDsn -Name HealthCheck -DsnType System -Platform $platform -ErrorAction SilentlyContinue
    if ($dsn) { Remove-OdbcDsn -Name HealthCheck -DsnType System -Platform $platform }
    Add-OdbcDsn -Name HealthCheck -DsnType System -Platform $platform -DriverName $driverName -SetPropertyValue @(
        "Server=$($CL.Sql.Ip),$($CL.Sql.Port)",'Database=CloudLabHealth','Trusted_Connection=No','Encrypt=Yes','TrustServerCertificate=No','HostnameInCertificate=sql.cloudlab.test') | Out-Null
}
$engine=Join-Path $install 'Engine'
$helper=Join-Path $engine 'Test-InfrastructureOdbc.ps1'
$existing=(Get-Content -Raw -LiteralPath $helper).Replace("`r`n","`n")
$sha=[Security.Cryptography.SHA256]::Create()
try { $actual=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($existing)))).Replace('-','').ToLowerInvariant() }
finally { $sha.Dispose() }
if ($actual -ne 'e7955df0fce95b4a48d25bec66a3fffd8a8f1998f3e9064a286407663d9f1059' -and $existing -cne $CL.HealthSql.ProbeScript.Replace("`r`n","`n")) { throw 'Unexpected existing SQL probe. Review release compatibility.' }
# Runtime adapter is tracked by CloudLab; the downloaded release ZIP is not changed.
[IO.File]::WriteAllText($helper,$CL.HealthSql.ProbeScript,[Text.UTF8Encoding]::new($false))
@{Vault=$CL.VaultName;Database='CloudLabHealth';HostName='sql.cloudlab.test';Address=$CL.Sql.Ip;Port=$CL.Sql.Port} |
    ConvertTo-Json | Set-Content (Join-Path $engine 'CloudLabSql.json') -Encoding utf8
# Protect the credential-fetching adapter and its settings from unprivileged modification.
& icacls.exe $engine /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /T | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect health engine files.' }
$configFile=Join-Path $install 'config/health.ini'
$configText=Get-Content -Raw -LiteralPath $configFile
if ([regex]::Matches($configText,'(?m)^DsnName=.*$').Count -ne 1) { throw 'Expected one DsnName setting.' }
$configText=[regex]::Replace($configText,'(?m)^DsnName=[^\r\n]*','DsnName=HealthCheck')
[IO.File]::WriteAllText($configFile,$configText,[Text.UTF8Encoding]::new($false))
foreach ($arch in 'System32','SysWOW64') {
    $exe=Join-Path $env:WINDIR "$arch/WindowsPowerShell/v1.0/powershell.exe"
    $answer=(& $exe -NoProfile -NonInteractive -File $helper | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $answer.available) { throw "Health SQL positive connection test failed ($arch)." }
    $answer=(& $exe -NoProfile -NonInteractive -File $helper -TestTlsRejection | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $answer.available) { throw "Health SQL negative hostname test failed ($arch)." }
}
if ($wasEnabled) { Enable-ScheduledTask -TaskName $taskName | Out-Null;Start-ScheduledTask -TaskName $taskName }
Remove-Item -LiteralPath $taskState
Write-Output '64-bit and 32-bit SQL probes passed, including permission checks and rejection of the wrong TLS hostname.'
