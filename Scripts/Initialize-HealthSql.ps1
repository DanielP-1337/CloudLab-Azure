#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([Security.SecureString]$PfxPassword)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Run on Windows with PowerShell 7.4 or later.' }
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root/Modules/CloudLab.Azure/HealthSql.psm1" -Force
. "$PSScriptRoot/Windows/SqlDeveloperMedia.ps1"
$path=Join-Path $root '.local/config/lab.psd1'
$text=Get-Content -Raw -LiteralPath $path
$c=Import-PowerShellDataFile -LiteralPath $path
if ($c.Environment -ne 'sandbox' -or $c.Sql.Name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,14}$') { throw 'Expected a sandbox and valid SQL VM name.' }
if (-not $PSCmdlet.ShouldProcess($path,'Prepare a separate local SQL CA/certificate, download ODBC MSI without installing it, and back up/update local config')) { return }
$dir=Join-Path $root '.local/pki/sql-health'
$lockPath=Join-Path $root '.local/releases/health-odbc.json'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
# PFX is encrypted; restrict all PKI files to this user and SYSTEM as well.
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $dir /inheritance:r /grant:r "*${sid}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect SQL PKI directory.' }
if (-not (Test-Path "$dir/manifest.json")) {
    if (Get-ChildItem -LiteralPath $dir -Force) { throw 'Incomplete SQL PKI exists. Preserve and review it before retrying.' }
    if (-not $PfxPassword) { $PfxPassword=Read-Host 'Choose a separate SQL PFX password (at least 16 characters)' -AsSecureString }
    if ($PfxPassword.Length -lt 16) { throw 'Use at least 16 characters.' }
    $ca=$null;$leaf=$null
    try {
        $ca=New-SelfSignedCertificate -Type Custom -Subject 'CN=CloudLab SQL Test Root CA' -CertStoreLocation Cert:\CurrentUser\My `
            -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
            -KeyUsage CertSign,CRLSign -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=0') -NotAfter (Get-Date).AddYears(1)
        $leaf=New-SelfSignedCertificate -Type Custom -Subject "CN=$($c.Sql.Name)" -DnsName @($c.Sql.Name,'sql.cloudlab.test') `
            -Signer $ca -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
            -Provider 'Microsoft RSA SChannel Cryptographic Provider' -KeySpec KeyExchange -KeyExportPolicy Exportable `
            -KeyUsage DigitalSignature,KeyEncipherment -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1') -NotAfter (Get-Date).AddDays(90)
        Export-Certificate -Cert $ca -FilePath "$dir/root.cer" | Out-Null
        Export-Certificate -Cert $leaf -FilePath "$dir/server.cer" | Out-Null
        Export-PfxCertificate -Cert $leaf -FilePath "$dir/server.pfx" -Password $PfxPassword -ChainOption EndEntityCertOnly | Out-Null
        @{Schema=1;ProjectId=$c.ProjectId;ComputerName=$c.Sql.Name;RootThumbprint=$ca.Thumbprint;ServerThumbprint=$leaf.Thumbprint} |
            ConvertTo-Json | Set-Content "$dir/manifest.json" -Encoding utf8
    } finally {
        # Remove temporary personal-store certificates and both private key containers.
        foreach ($cert in @($leaf,$ca)) { if ($cert) { Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey -ErrorAction Stop } }
    }
}
if (-not (Test-Path -LiteralPath $lockPath)) {
    $media=Join-Path $root '.local/media/health-odbc'
    New-Item -ItemType Directory -Path $media -Force | Out-Null
    $msi=Join-Path $media 'msodbcsql.msi'
    $uri='https://go.microsoft.com/fwlink/?clcid=0x409&linkid=2378279'
    Invoke-WebRequest -Uri $uri -OutFile $msi
    Assert-CLMicrosoftBinary $msi
    New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
    @{Uri=$uri;Sha256=(Get-FileHash $msi -Algorithm SHA256).Hash;Version='18.7.1.1'} | ConvertTo-Json | Set-Content $lockPath -Encoding utf8
}
$new=Set-CLHealthSqlConfigText $text
$tmp="$path.health-sql.tmp.psd1"
try {
    [IO.File]::WriteAllText($tmp,$new,[Text.UTF8Encoding]::new($false))
    $candidate=Import-PowerShellDataFile -LiteralPath $tmp
    Read-CLHealthSql $candidate $root | Out-Null
    if ($new -cne $text) {
        Copy-Item -LiteralPath $path -Destination "$path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
Write-Output 'Local SQL PKI, ODBC lock and config ready. No trusted-root store, Azure resource, or SQL installation changed.'
