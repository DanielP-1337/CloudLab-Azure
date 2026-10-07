#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param([string]$GatewayIp,[switch]$Remove)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Windows client required.' }
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/LabTls.psm1" -Force
$c=Import-PowerShellDataFile "$root/.local/config/lab.psd1"
$dir=Join-Path $root '.local/pki/lab'
$manifest=Get-Content -Raw "$dir/manifest.json" | ConvertFrom-Json
if ($manifest.ProjectId -ne $c.ProjectId) { throw 'Certificate project mismatch.' }
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes("$dir/root-ca.cer"))
$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
try {
    if ($cert.Thumbprint -ne $manifest.RootThumbprint) { throw 'Root certificate mismatch.' }
    if (-not $Remove) { Read-CLLabTls $c $root | Out-Null }
    $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts'
    $original=[IO.File]::ReadAllText($hosts)
    $updated=Update-CLLabHostsText $original $c.ProjectId $GatewayIp -Remove:$Remove
    $statePath=Join-Path $dir 'client-state.json'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $state=if (Test-Path -LiteralPath $statePath) { Get-Content -Raw $statePath | ConvertFrom-Json } else { $null }
    if ($state -and ($state.UserSid -ne $sid -or $state.RootThumbprint -ne $cert.Thumbprint)) { throw 'Client state belongs to another user or root. Use the original Windows account.' }
    $action=if ($Remove) { 'Remove this project hosts block and root trust added by this helper' } else { 'Map two .test names and trust the lab root in CurrentUser/Root' }
    if (-not $PSCmdlet.ShouldProcess($hosts,$action)) { return }
    $store.Open('ReadWrite')
    if (-not $Remove) {
        if (-not $state) {
            $present=@($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint).Count -gt 0
            $state=@{UserSid=$sid;RootThumbprint=$cert.Thumbprint;ImportedRoot=(-not $present)}
            $state | ConvertTo-Json | Set-Content -LiteralPath $statePath
        }
        $store.Add($cert)
    }
    if ($updated -ne $original) {
        Copy-Item -LiteralPath $hosts -Destination (Join-Path $dir ('hosts-'+[guid]::NewGuid().ToString('N')+'.bak'))
        [IO.File]::WriteAllText($hosts,$updated,[Text.UTF8Encoding]::new($false))
    }
    if ($Remove -and $state) {
        if ($state.ImportedRoot) { $store.Remove($cert) }
        Remove-Item -LiteralPath $statePath
    }
    Clear-DnsClientCache
    Write-Host 'Local client access updated. No Azure operation. Restart the browser if needed.'
} finally { $store.Close(); $cert.Dispose() }
