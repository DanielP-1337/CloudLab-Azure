# Runs as LocalSystem on the SQL VM, after the normal SQL installation.
$h=$CL.HealthSql
if ($CL.Sql.Instance -ne 'MSSQLSERVER' -or $h.Database -ne 'CloudLabHealth' -or $h.Login -ne 'cloudlab_health') { throw 'Unexpected SQL health profile.' }
# Check database ownership before changing SQL authentication or certificates.
$project=([guid]$CL.ProjectId).ToString()
$preflight=Invoke-CLSqlLocal 'MSSQLSERVER' "SELECT DB_ID(N'CloudLabHealth') AS DbId, SUSER_ID(N'cloudlab_health') AS LoginId"
if ($preflight.Rows[0].DbId -isnot [DBNull]) {
    $owner=Invoke-CLSqlLocal 'MSSQLSERVER' "USE [CloudLabHealth]; SELECT CONVERT(nvarchar(128),value) AS Owner FROM sys.extended_properties WHERE class=0 AND name=N'CloudLabProject'"
    if ($owner.Rows.Count -ne 1 -or $owner.Rows[0].Owner -ne $project) { throw 'Refusing to configure another project database.' }
} elseif ($preflight.Rows[0].LoginId -isnot [DBNull]) { throw 'Existing health login has no owned database.' }
$version=Invoke-CLSqlLocal 'MSSQLSERVER' "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')) AS Version"
if ($version.Rows[0].Version -ne 16) { throw 'Expected SQL Server 2022.' }
$rootCert=New-Object Security.Cryptography.X509Certificates.X509Certificate2
$rootCert.Import([Convert]::FromBase64String($h.RootDerBase64))
if ($rootCert.Thumbprint -ne $h.RootThumbprint) { throw 'SQL root mismatch.' }
$store=New-Object Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
try { $store.Open('ReadWrite');$store.Add($rootCert) } finally { $store.Close();$rootCert.Dispose() }
$collection=New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
try {
    $pfx=Get-CLSecret $CL.VaultName $h.CertificateSecret
    $flags=[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
    $collection.Import([Convert]::FromBase64String($pfx),'',$flags)
    $keys=@($collection | Where-Object HasPrivateKey)
    if ($keys.Count -ne 1 -or $keys[0].Thumbprint -ne $h.ServerThumbprint -or $keys[0].NotAfter -lt (Get-Date).AddDays(7)) { throw 'Unexpected SQL server certificate.' }
    $cert=$keys[0]
    $key=$cert.PrivateKey
    if ($key -isnot [Security.Cryptography.RSACryptoServiceProvider] -or $key.CspKeyContainerInfo.KeyNumber -ne 'Exchange' -or -not $key.CspKeyContainerInfo.MachineKeyStore) {
        throw 'SQL requires a machine legacy CSP key with AT_KEYEXCHANGE.'
    }
    $my=New-Object Security.Cryptography.X509Certificates.X509Store('My','LocalMachine')
    try { $my.Open('ReadWrite');$my.Add($cert) } finally { $my.Close() }
    $keyPath=Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $key.CspKeyContainerInfo.UniqueKeyContainerName
    $acl=Get-Acl -LiteralPath $keyPath
    $rule=New-Object Security.AccessControl.FileSystemAccessRule('NT SERVICE\MSSQLSERVER','Read','Allow')
    $acl.SetAccessRule($rule);Set-Acl -LiteralPath $keyPath -AclObject $acl
} finally { $pfx=$null;foreach ($cert in $collection) { $cert.Dispose() } }
$map=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
$base="HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($map.MSSQLSERVER)\MSSQLServer"
Set-ItemProperty "$base\SuperSocketNetLib" -Name Certificate -Value $h.ServerThumbprint.ToLowerInvariant()
Set-ItemProperty "$base\SuperSocketNetLib" -Name ForceEncryption -Value 1
Set-ItemProperty $base -Name LoginMode -Value 2
Restart-Service MSSQLSERVER -ErrorAction Stop
(Get-Service MSSQLSERVER).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(60))
# The database is exclusively owned by this disposable project; never adopt another database.
$project=([guid]$CL.ProjectId).ToString()
$check=Invoke-CLSqlLocal 'MSSQLSERVER' "SELECT DB_ID(N'CloudLabHealth') AS DbId, SUSER_ID(N'cloudlab_health') AS LoginId"
if ($check.Rows[0].DbId -is [DBNull]) {
    if ($check.Rows[0].LoginId -isnot [DBNull]) { throw 'Existing health login has no owned database. Review manually.' }
    Invoke-CLSqlLocal 'MSSQLSERVER' "CREATE DATABASE [CloudLabHealth]; SELECT 1 AS Ok" | Out-Null
    Invoke-CLSqlLocal 'MSSQLSERVER' "USE [CloudLabHealth]; EXEC sys.sp_addextendedproperty @name=N'CloudLabProject',@value=N'$project'; SELECT 1 AS Ok" | Out-Null
} else {
    $owner=Invoke-CLSqlLocal 'MSSQLSERVER' "USE [CloudLabHealth]; SELECT CONVERT(nvarchar(128),value) AS Owner FROM sys.extended_properties WHERE class=0 AND name=N'CloudLabProject'"
    if ($owner.Rows.Count -ne 1 -or $owner.Rows[0].Owner -ne $project) { throw 'Refusing to adopt an existing database.' }
}
$password=$null;$escaped=$null
try {
    $password=Get-CLSecret $CL.VaultName $h.PasswordSecret
    if ($password.Length -lt 32 -or $password.Length -gt 128) { throw 'Unexpected health login password length.' }
    $escaped=$password.Replace("'","''")
    if ($check.Rows[0].LoginId -is [DBNull]) {
        Invoke-CLSqlLocal 'MSSQLSERVER' "CREATE LOGIN [cloudlab_health] WITH PASSWORD=N'$escaped', DEFAULT_DATABASE=[CloudLabHealth], CHECK_POLICY=ON, CHECK_EXPIRATION=OFF; SELECT 1 AS Ok" | Out-Null
        Invoke-CLSqlLocal 'MSSQLSERVER' "USE [CloudLabHealth]; CREATE USER [cloudlab_health] FOR LOGIN [cloudlab_health]; SELECT 1 AS Ok" | Out-Null
    } else {
        $sid=Invoke-CLSqlLocal 'MSSQLSERVER' "USE [CloudLabHealth]; SELECT COUNT(*) AS Matches FROM sys.database_principals WHERE name=N'cloudlab_health' AND sid=SUSER_SID(N'cloudlab_health')"
        if ($sid.Rows[0].Matches -ne 1) { throw 'Login ownership mismatch or partial setup. Review manually.' }
        # Explicit rerun also synchronizes a deliberately rotated vault password.
        Invoke-CLSqlLocal 'MSSQLSERVER' "ALTER LOGIN [cloudlab_health] WITH PASSWORD=N'$escaped'; SELECT 1 AS Ok" | Out-Null
    }
} catch { throw 'SQL login provisioning failed. Review protected SQL diagnostics; no password is printed.' }
finally { $password=$null;$escaped=$null }
Invoke-CLSqlLocal 'MSSQLSERVER' @"
USE [CloudLabHealth];
IF OBJECT_ID(N'dbo.HealthSample',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.HealthSample (Id int NOT NULL PRIMARY KEY, Label nvarchar(64) NOT NULL);
 INSERT dbo.HealthSample VALUES (1,N'Synthetic CloudLab smoke test');
END;
GRANT CONNECT TO [cloudlab_health];
DENY INSERT, UPDATE, DELETE, ALTER, CONTROL ON OBJECT::dbo.HealthSample TO [cloudlab_health];
SELECT 1 AS Ok;
"@ | Out-Null
$imagePath=([string]$CL.App.ImagePath).Replace("'","''")
Invoke-CLSqlLocal 'MSSQLSERVER' @"
USE [CloudLabHealth];
EXEC(N'CREATE OR ALTER PROCEDURE dbo.ReadHealth AS
BEGIN SET NOCOUNT ON;
 SELECT CONVERT(nvarchar(128),SERVERPROPERTY(''ServerName'')), DB_NAME(), N''$($imagePath.Replace("'","''"))''
 FROM dbo.HealthSample WHERE Id=1;
END');
GRANT EXECUTE ON OBJECT::dbo.ReadHealth TO [cloudlab_health];
SELECT 1 AS Ok;
"@ | Out-Null
Write-Output 'Owned synthetic database, restricted login, SQL certificate and forced encryption configured.'
