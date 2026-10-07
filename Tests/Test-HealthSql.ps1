# Offline: no certificate store, SQL server, Key Vault or Azure operations.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root/Modules/CloudLab.Azure/HealthSql.psm1" -Force
function Assert-Throws([scriptblock]$Block) {
    $failed=$false;try { & $Block | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Expected rejection.' }
}
$c=@{Environment='sandbox';ProjectId='test-project';HealthSql=@{Enabled=$true};App=@{Provider='InfrastructureHealth'}
    Sql=@{MajorVersion=16;Instance='MSSQLSERVER';Name='lab-sql';Databases=@('CloudLabHealth')}}
Assert-CLHealthSql $c
$c.Environment='production';Assert-Throws { Assert-CLHealthSql $c };$c.Environment='sandbox'
$c.Sql.Databases=@('other');Assert-Throws { Assert-CLHealthSql $c };$c.Sql.Databases=@('CloudLabHealth')
$c.Sql.Instance='OTHER';Assert-Throws { Assert-CLHealthSql $c };$c.Sql.Instance='MSSQLSERVER'
foreach ($nl in @("`n","`r`n")) {
    $source="@{$nl    Sql = @{ Databases = @('REPLACE-database'); MaxMemoryMB = 4096 }$nl    App = @{ Name = 'keep-me' }$nl}$nl"
    $new=Set-CLHealthSqlConfigText $source
    if ((Set-CLHealthSqlConfigText $new) -cne $new) { throw 'Config migration is not idempotent.' }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($new,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Generated config does not parse.' }
    $table=$ast.Find({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true).SafeGetValue()
    if (-not $table.HealthSql.Enabled -or $table.Sql.Databases[0] -ne 'CloudLabHealth' -or $table.App.Name -ne 'keep-me' -or $table.Sql.MaxMemoryMB -ne 4096) { throw 'Config values changed unexpectedly.' }
}
# Exercise certificate verification with ephemeral in-memory keys, no Windows store.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-healthsql-'+[guid]::NewGuid().ToString('N'))
$rootKey=[Security.Cryptography.RSA]::Create(2048);$leafKey=[Security.Cryptography.RSA]::Create(2048)
$ca=$null;$leaf=$null
try {
    New-Item -ItemType Directory -Path "$temp/.local/pki/sql-health","$temp/.local/releases" -Force | Out-Null
    $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Offline SQL Test CA',$rootKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $ca=$req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(60))
    $req=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=lab-sql',$leafKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oids=[Security.Cryptography.OidCollection]::new();[void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$false))
    $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddDnsName('sql.cloudlab.test');$req.CertificateExtensions.Add($san.Build())
    $leaf=$req.Create($ca,[DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(30),[byte[]](1,2,3,4))
    [IO.File]::WriteAllBytes("$temp/.local/pki/sql-health/root.cer",$ca.RawData)
    [IO.File]::WriteAllBytes("$temp/.local/pki/sql-health/server.cer",$leaf.RawData)
    @{Schema=1;ProjectId=$c.ProjectId;ComputerName='lab-sql';RootThumbprint=$ca.Thumbprint;ServerThumbprint=$leaf.Thumbprint} | ConvertTo-Json | Set-Content "$temp/.local/pki/sql-health/manifest.json"
    @{Uri='https://go.microsoft.com/fwlink/?clcid=0x409&linkid=2378279';Sha256=('a'*64)} | ConvertTo-Json | Set-Content "$temp/.local/releases/health-odbc.json"
    $h=Read-CLHealthSql $c $temp
    if ($h.HostName -ne 'sql.cloudlab.test' -or $h.PasswordSecret -ne 'health-sql-password') { throw 'Unexpected profile.' }
    $c.ProjectId='other-project';Assert-Throws { Read-CLHealthSql $c $temp };$c.ProjectId='test-project'
} finally {
    foreach ($cert in @($leaf,$ca)) { if ($cert) { $cert.Dispose() } }
    $rootKey.Dispose();$leafKey.Dispose();Remove-Item -LiteralPath $temp -Recurse -Force
}
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
$c.HealthSql=@{Enabled=$true;ProbeScript=(Get-Content -Raw "$root/Scripts/Windows/Invoke-HealthSqlProbe.ps1")}
foreach ($file in 'Configure-HealthSqlServer.ps1','Configure-HealthSqlClient.ps1') {
    $script=Get-CLGuestPayload $c "$root/Scripts/Windows/Common.ps1" Windows
    $script+="`n"+(Get-Content -Raw "$root/Scripts/Windows/SqlDeveloperMedia.ps1")
    $script+="`n"+(Get-Content -Raw "$root/Scripts/Windows/$file")
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseInput($script,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw 'Composed SQL adapter payload does not parse.' }
}
Write-Output 'Offline SQL profile, config migration, certificate chain and payload parsing checks passed.'
