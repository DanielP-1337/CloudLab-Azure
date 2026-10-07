#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([Security.SecureString]$PfxPassword,[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
Write-Warning 'COST NOTICE: This uploads a certificate to an existing Azure Key Vault. Key Vault operations/storage may incur charges. No VM or gateway is created.'
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/LabTls.psm1" -Force
$c=Import-PowerShellDataFile "$root/.local/config/lab.psd1"
if (-not $c.LabTlsEnabled) { throw 'Enable local lab TLS first.' }
$tls=Read-CLLabTls $c $root
$expectedUri="https://$($c.VaultName).vault.azure.net/secrets/$($c.CertificateSecret)"
if ($c.GatewayCertificateSecretUri -cne $expectedUri) { throw 'Expected the versionless certificate backing-secret URI.' }
if (-not $PSCmdlet.ShouldProcess($c.VaultName,'Import the password-protected lab server PFX as a Key Vault certificate')) { return }
if (-not $EnableBillableResources) { throw 'Use -EnableBillableResources after reviewing the cost notice.' }
Import-Module Az.Accounts
Import-Module Az.KeyVault
$context=Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $c.SubscriptionId -or $context.Tenant.Id -ne $c.TenantId) { throw 'Sign in to the configured Azure subscription first.' }
$vault=Get-AzKeyVault -VaultName $c.VaultName -ResourceGroupName $c.SharedResourceGroup -ErrorAction Stop
if (-not $vault) { throw 'The retained Key Vault must already exist.' }
$matches=@(Get-AzKeyVaultCertificate -VaultName $c.VaultName -ErrorAction Stop | Where-Object Name -eq $c.CertificateSecret)
$existing=if ($matches.Count) { Get-AzKeyVaultCertificate -VaultName $c.VaultName -Name $c.CertificateSecret -ErrorAction Stop } else { $null }
if ($existing) {
    if ($existing.Thumbprint -ne $tls.ServerThumbprint) { throw 'A different certificate already exists. Review rotation explicitly.' }
    Write-Host 'Matching Key Vault certificate already exists. No import performed.'
    return
}
if (-not $PfxPassword) { $PfxPassword=Read-Host 'PFX password chosen during local preparation' -AsSecureString }
$collection=[Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
$pointer=[IntPtr]::Zero
try {
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $file=Join-Path $root '.local/pki/lab/server.pfx'
    $collection.Import([IO.File]::ReadAllBytes($file),$plain,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $keys=@($collection | Where-Object HasPrivateKey)
    if ($keys.Count -ne 1 -or $keys[0].Thumbprint -ne $tls.ServerThumbprint) { throw 'Unexpected PFX private key or certificate.' }
    $imported=Import-AzKeyVaultCertificate -VaultName $c.VaultName -Name $c.CertificateSecret -FilePath $file -Password $PfxPassword -ErrorAction Stop
    if ($imported.Thumbprint -ne $tls.ServerThumbprint) { throw 'Imported certificate differs from local manifest.' }
    Write-Host 'Lab server certificate imported. The private root CA key was not uploaded.'
} finally {
    $plain=$null
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    foreach ($cert in $collection) { $cert.Dispose() }
}
