Initialize-CLDataDisk -Letter $CL.App.DriveLetter -ExpectedGB $CL.App.DiskGB
$result = Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Net-Ext45,Web-ISAPI-Ext,Web-ISAPI-Filter,Web-Mgmt-Tools,Web-Scripting-Tools
if (-not $result.Success -or [string]$result.RestartNeeded -eq 'Yes') { throw 'IIS provisioning needs a reboot or failed. Reboot and rerun.' }
Import-Module WebAdministration
New-Item -ItemType Directory -Path $CL.App.ImagePath -Force | Out-Null
New-Item -ItemType Directory -Path $CL.App.SitePath -Force | Out-Null
if (-not (Test-Path -LiteralPath $CL.App.InstallerPath)) { throw 'Stage the reviewed CloudLab installer wrapper first.' }
if ((Get-FileHash -LiteralPath $CL.App.InstallerPath -Algorithm SHA256).Hash -ne $CL.App.InstallerSha256) { throw 'CloudLab installer checksum mismatch.' }
# The wrapper contract is documented; it must throw on failures, including native exit codes.
& $CL.App.InstallerPath -Configuration $CL
if (-not (Test-Path "IIS:\AppPools\$($CL.App.AppPoolName)")) { throw 'Vendor wrapper must create the configured app pool.' }
if (-not (Test-Path "IIS:\Sites\$($CL.App.SiteName)")) { throw 'Vendor wrapper must create the configured IIS site.' }
$pfxText = Get-CLSecret $CL.VaultName $CL.CertificateSecret
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
$cert.Import([Convert]::FromBase64String($pfxText),'',$flags)
if (-not $cert.HasPrivateKey -or $cert.NotAfter -lt (Get-Date).AddDays(7)) { throw 'Missing or expiring IIS TLS certificate.' }
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','LocalMachine')
try { $store.Open('ReadWrite'); $store.Add($cert) } finally { $store.Close() }
if (-not (Get-WebBinding -Name $CL.App.SiteName -Protocol https -Port 443 -HostHeader $CL.BackendHost)) {
    New-WebBinding -Name $CL.App.SiteName -Protocol https -Port 443 -HostHeader $CL.BackendHost -SslFlags 1
}
(Get-WebBinding -Name $CL.App.SiteName -Protocol https -Port 443 -HostHeader $CL.BackendHost).AddSslCertificate($cert.Thumbprint,'My')
Get-NetFirewallRule -DisplayName 'CloudLab HTTPS' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'CloudLab HTTPS' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 443 -RemoteAddress $CL.Keycloak.Ip | Out-Null
# The NSG blocks other IIS bindings from external access. Test vendor URL generation.
