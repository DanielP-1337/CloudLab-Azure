#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([Security.SecureString]$PfxPassword,[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
Write-Warning 'COST NOTICE: Imports a SQL certificate and creates passwords in an existing Azure Key Vault. Key Vault storage and operations may incur charges.'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root/Modules/CloudLab.Azure/HealthSql.psm1" -Force
$c=Import-PowerShellDataFile "$root/.local/config/lab.psd1"
$h=Read-CLHealthSql $c $root
if (-not $PSCmdlet.ShouldProcess($c.VaultName,'Import SQL TLS PFX and create/reuse the project-owned SQL health and database master-key passwords')) { return }
if (-not $EnableBillableResources) { throw 'Use -EnableBillableResources after reviewing the cost notice.' }
Import-Module Az.Accounts
Import-Module Az.KeyVault
$context=Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $c.SubscriptionId -or $context.Tenant.Id -ne $c.TenantId) { throw 'Sign in to the configured Azure subscription first.' }
$vault=Get-AzKeyVault -VaultName $c.VaultName -ResourceGroupName $c.SharedResourceGroup -ErrorAction Stop
if (-not $vault) { throw 'The retained Key Vault must already exist.' }
$existing=@(Get-AzKeyVaultCertificate -VaultName $c.VaultName | Where-Object Name -eq $h.CertificateSecret)
if ($existing.Count) {
    $cert=Get-AzKeyVaultCertificate -VaultName $c.VaultName -Name $h.CertificateSecret
    if ($cert.Thumbprint -ne $h.ServerThumbprint -or $cert.Tags['CloudLabProject'] -ne $c.ProjectId) { throw 'Refusing to replace another SQL certificate.' }
} else {
    if (Get-AzKeyVaultSecret -VaultName $c.VaultName | Where-Object Name -eq $h.CertificateSecret) { throw 'Conflicting backing-secret name.' }
    if (-not $PfxPassword) { $PfxPassword=Read-Host 'SQL PFX password chosen during local preparation' -AsSecureString }
    $collection=[Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $ptr=[IntPtr]::Zero
    try {
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
        $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $file=Join-Path $root '.local/pki/sql-health/server.pfx'
        $collection.Import([IO.File]::ReadAllBytes($file),$plain,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        $keys=@($collection | Where-Object HasPrivateKey)
        if ($keys.Count -ne 1 -or $keys[0].Thumbprint -ne $h.ServerThumbprint) { throw 'SQL PFX does not match the prepared leaf certificate.' }
        Import-AzKeyVaultCertificate -VaultName $c.VaultName -Name $h.CertificateSecret -FilePath $file -Password $PfxPassword -Tag @{CloudLabProject=$c.ProjectId} | Out-Null
    } finally {
        $plain=$null
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        foreach ($cert in $collection) { $cert.Dispose() }
    }
}
foreach ($secretName in @($h.PasswordSecret,'health-sql-dmk-password')) {
$existing=@(Get-AzKeyVaultSecret -VaultName $c.VaultName | Where-Object Name -eq $secretName)
if ($existing.Count) {
    if ($existing[0].Tags['CloudLabProject'] -ne $c.ProjectId) { throw 'Refusing to reuse another project password.' }
} else {
    $bytes=[byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $plain='aA9!'+[Convert]::ToBase64String($bytes)
    $secure=ConvertTo-SecureString $plain -AsPlainText -Force
    try { Set-AzKeyVaultSecret -VaultName $c.VaultName -Name $secretName -SecretValue $secure -Tag @{CloudLabProject=$c.ProjectId} | Out-Null }
    finally { $plain=$null;$secure.Dispose();[Array]::Clear($bytes,0,$bytes.Length) }
}
}
Write-Output 'SQL certificate and passwords are ready in Key Vault. No secret value was printed or written to the repository.'
