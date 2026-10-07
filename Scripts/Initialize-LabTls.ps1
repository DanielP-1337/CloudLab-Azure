#requires -Version 7.4
# Local preparation only; no Azure call and no certificate-store or hosts changes.
[CmdletBinding(SupportsShouldProcess)]
param([Security.SecureString]$PfxPassword)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Run local PKI preparation on Windows.' }
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/LabTls.psm1" -Force
$path=Join-Path $root '.local/config/lab.psd1'
$c=Import-PowerShellDataFile -LiteralPath $path
$projectGuid=[guid]::Empty
if (-not [guid]::TryParse([string]$c.ProjectId,[ref]$projectGuid) -or $projectGuid -eq [guid]::Empty) { throw 'Set a valid local ProjectId first.' }
if (Get-ChildItem "$root/.local/state" -Filter '*.json' -File -ErrorAction SilentlyContinue) { throw 'This helper is only for a lab that has not been deployed. Do not delete lifecycle state.' }
$text=[IO.File]::ReadAllText($path)
$updated=Set-CLLabConfigText $text $c.VaultName $c.CertificateSecret
$dir=Join-Path $root '.local/pki/lab'
if (-not $PSCmdlet.ShouldProcess($path,'Create/reuse local lab PKI and configure .test names; back up changed config')) { return }
if (-not (Test-Path -LiteralPath (Join-Path $dir 'manifest.json'))) {
    if (Test-Path -LiteralPath $dir) { throw 'Incomplete PKI directory exists. Review it before retrying.' }
    if (-not $PfxPassword) { $PfxPassword=Read-Host 'Choose a PFX password (at least 16 characters); keep it for the later Key Vault import' -AsSecureString }
    if ($PfxPassword.Length -lt 16) { throw 'Use a PFX password with at least 16 characters.' }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Restrict private material to this Windows user and LocalSystem before writing.
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $dir /inheritance:r /grant:r "*${sid}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict the PKI directory ACL.' }
    New-CLLabCertificateFiles $dir $c.ProjectId $PfxPassword
}
if (-not (Test-Path -LiteralPath (Join-Path $dir 'server.pfx'))) { throw 'Local server PFX is missing; review the PKI directory.' }
$candidate="$path.tls-candidate.psd1"
if (Test-Path -LiteralPath $candidate) { throw 'TLS candidate file exists; review it first.' }
try {
    [IO.File]::WriteAllText($candidate,$updated,[Text.UTF8Encoding]::new($false))
    $checked=Import-PowerShellDataFile -LiteralPath $candidate
    $tls=Read-CLLabTls $checked $root
    if ($updated -ne $text) {
        Copy-Item -LiteralPath $path -Destination "$path.$([guid]::NewGuid().ToString('N')).bak"
        Move-Item -LiteralPath $candidate -Destination $path -Force
    }
    Write-Host "Local lab TLS ready. Root thumbprint: $($tls.RootThumbprint)"
    Write-Host 'No trust store, hosts file, or Azure resource changed. Private root key was not retained.'
} finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate } }
