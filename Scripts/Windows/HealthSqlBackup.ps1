# SQL column-encryption test keys are unrelated to the SQL transport TLS certificate.
function Get-CLHealthMasterKeySecret {
    param([string]$Version)
    if ($Version -and $Version -notmatch '^[a-fA-F0-9]{32}$') { throw 'Invalid master-key secret version.' }
    $path='health-sql-dmk-password'
    if ($Version) { $path+='/'+$Version }
    $token=$null;$secret=$null
    try {
        $token=(Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net').access_token
        for ($i=0;$i -lt 12;$i++) {
            try {
                $secret=Invoke-RestMethod -Headers @{Authorization="Bearer $token"} -Uri "https://$($CL.VaultName).vault.azure.net/secrets/${path}?api-version=7.4"
                break
            } catch { if ($i -eq 11) { throw 'Cannot retrieve the retained database master-key password.' }; Start-Sleep -Seconds 5 }
        }
        $resolved=([string]$secret.id).Split('/')[-1]
        if ($resolved -notmatch '^[a-fA-F0-9]{32}$' -or ($Version -and $resolved -ne $Version) -or
            $secret.tags.CloudLabProject -ne $CL.ProjectId -or ([string]$secret.value).Length -lt 16) { throw 'Master-key secret identity/ownership mismatch.' }
        return @{Version=$resolved;Value=[string]$secret.value}
    } finally { $token=$null;$secret=$null }
}
function Initialize-CLHealthColumnEncryption {
    $record=Invoke-CLSqlLocal $CL.Sql.Instance "USE [CloudLabHealth]; SELECT CONVERT(nvarchar(128),value) AS Version FROM sys.extended_properties WHERE class=0 AND name=N'CloudLabDmkSecretVersion'"
    if ($record.Rows.Count -gt 1) { throw 'Ambiguous master-key metadata.' }
    $version=if ($record.Rows.Count) { [string]$record.Rows[0].Version } else { '' }
    $secret=Get-CLHealthMasterKeySecret -Version $version
    $password=$null;$query=$null
    try {
        $password=$secret.Value.Replace("'","''")
        if (-not $version) {
            # Only a new, empty generic hierarchy may be provisioned. Never replace existing keys.
            $query=@"
USE [CloudLabHealth]; SET XACT_ABORT ON;
IF EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name IN ('##MS_DatabaseMasterKey##','CloudLabColumnKey'))
 OR EXISTS (SELECT 1 FROM sys.certificates WHERE name='CloudLabColumnCertificate')
 OR OBJECT_ID(N'dbo.CloudLabEncryptedSample') IS NOT NULL
 THROW 51000, 'Existing encryption objects require manual review; no keys replaced.', 1;
BEGIN TRANSACTION;
CREATE MASTER KEY ENCRYPTION BY PASSWORD=N'$password';
CREATE CERTIFICATE [CloudLabColumnCertificate] WITH SUBJECT=N'CloudLab synthetic column encryption';
CREATE SYMMETRIC KEY [CloudLabColumnKey] WITH ALGORITHM=AES_128 ENCRYPTION BY CERTIFICATE [CloudLabColumnCertificate];
CREATE TABLE dbo.CloudLabEncryptedSample (Id int NOT NULL PRIMARY KEY, Ciphertext varbinary(8000) NOT NULL);
OPEN SYMMETRIC KEY [CloudLabColumnKey] DECRYPTION BY CERTIFICATE [CloudLabColumnCertificate];
INSERT dbo.CloudLabEncryptedSample VALUES (1,EncryptByKey(Key_GUID(N'CloudLabColumnKey'),CONVERT(nvarchar(128),N'Synthetic encrypted CloudLab value')));
CLOSE SYMMETRIC KEY [CloudLabColumnKey];
EXEC sys.sp_addextendedproperty @name=N'CloudLabDmkSecretVersion', @value=N'$($secret.Version)';
COMMIT; SELECT 1 AS Ok;
"@
            Invoke-CLSqlLocal $CL.Sql.Instance $query | Out-Null
        }
        return $secret.Version
    } catch { throw 'Synthetic column-encryption preparation failed. Existing encryption keys were not replaced.' }
    finally { $password=$null;$query=$null;$secret=$null }
}
# Shared guest helpers: only the owned synthetic CloudLabHealth database.
function Invoke-CLHealthRestore {
    param([string]$BackupFile,[Parameter(Mandatory)][string]$MasterKeySecretVersion,[switch]$Keep)
    if ($CL.Sql.DriveLetter -notmatch '^[A-Za-z]$') { throw 'Invalid SQL data drive.' }
    $project=([guid]$CL.ProjectId).ToString()
    $literal=$BackupFile.Replace("'","''")
    $header=Invoke-CLSqlLocal $CL.Sql.Instance "RESTORE HEADERONLY FROM DISK=N'$literal'" 300
    if ($header.Rows.Count -ne 1 -or $header.Rows[0].DatabaseName -ne 'CloudLabHealth' -or
        $header.Rows[0].BackupType -ne 1 -or -not $header.Rows[0].HasBackupChecksums -or -not $header.Rows[0].IsCopyOnly) { throw 'Expected one checksummed copy-only CloudLabHealth full backup.' }
    Invoke-CLSqlLocal $CL.Sql.Instance "RESTORE VERIFYONLY FROM DISK=N'$literal' WITH CHECKSUM; SELECT 1 AS Ok" 1200 | Out-Null
    $files=Invoke-CLSqlLocal $CL.Sql.Instance "RESTORE FILELISTONLY FROM DISK=N'$literal'" 300
    $data=@($files.Rows | Where-Object Type -eq 'D');$log=@($files.Rows | Where-Object Type -eq 'L')
    if ($files.Rows.Count -ne 2 -or $data.Count -ne 1 -or $log.Count -ne 1) { throw 'Expected one data file and one log file.' }
    $required=[long]$data[0].Size+[long]$log[0].Size
    if ($required -gt 8GB -or (Get-Volume -DriveLetter $CL.Sql.DriveLetter).SizeRemaining -lt ($required+2GB)) { throw 'Restore exceeds lab disk budget/free space.' }
    $name='CloudLabRestore_'+[guid]::NewGuid().ToString('N')
    $exists=Invoke-CLSqlLocal $CL.Sql.Instance "SELECT DB_ID(N'$name') AS Id"
    if ($exists.Rows[0].Id -isnot [DBNull]) { throw 'Restore target already exists.' }
    $base="$($CL.Sql.DriveLetter):\SQL"
    $mdf="$base\Data\$name.mdf";$ldf="$base\Log\$name.ldf"
    if ((Test-Path -LiteralPath $mdf) -or (Test-Path -LiteralPath $ldf)) { throw 'Restore target files already exist.' }
    $d=([string]$data[0].LogicalName).Replace("'","''");$l=([string]$log[0].LogicalName).Replace("'","''")
    $attempted=$false;$passed=$false
    try {
        $attempted=$true
        Invoke-CLSqlLocal $CL.Sql.Instance "RESTORE DATABASE [$name] FROM DISK=N'$literal' WITH MOVE N'$d' TO N'$mdf', MOVE N'$l' TO N'$ldf', CHECKSUM, RECOVERY, RESTRICTED_USER; SELECT 1 AS Ok" 1200 | Out-Null
        $owner=Invoke-CLSqlLocal $CL.Sql.Instance "USE [$name]; SELECT CONVERT(nvarchar(128),value) AS Owner FROM sys.extended_properties WHERE class=0 AND name=N'CloudLabProject'"
        if ($owner.Rows.Count -ne 1 -or $owner.Rows[0].Owner -ne $project) { throw 'Restored database belongs to another project.' }
        $check=Invoke-CLSqlLocal $CL.Sql.Instance "DBCC CHECKDB ([$name]) WITH NO_INFOMSGS, TABLERESULTS" 1200
        if ($check.Rows.Count) { throw 'DBCC CHECKDB reported problems.' }
        $row=Invoke-CLSqlLocal $CL.Sql.Instance "USE [$name]; SELECT COUNT(*) AS Matches FROM dbo.HealthSample WHERE Id=1 AND Label=N'Synthetic CloudLab smoke test'"
        if ($row.Rows[0].Matches -ne 1) { throw 'Synthetic reference row missing after restore.' }
        $secret=Get-CLHealthMasterKeySecret -Version $MasterKeySecretVersion
        $password=$null;$query=$null
        try {
            $password=$secret.Value.Replace("'","''")
            # Explicit password opening also supports a new SQL instance with a different SMK.
            $query=@"
USE [$name];
OPEN MASTER KEY DECRYPTION BY PASSWORD=N'$password';
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id=DB_ID() AND is_master_key_encrypted_by_server=1)
 ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;
OPEN SYMMETRIC KEY [CloudLabColumnKey] DECRYPTION BY CERTIFICATE [CloudLabColumnCertificate];
SELECT COUNT(*) AS Matches FROM dbo.CloudLabEncryptedSample
 WHERE Id=1 AND CONVERT(nvarchar(128),DecryptByKey(Ciphertext))=N'Synthetic encrypted CloudLab value';
CLOSE SYMMETRIC KEY [CloudLabColumnKey]; CLOSE MASTER KEY;
"@
            $decrypted=Invoke-CLSqlLocal $CL.Sql.Instance $query
            if ($decrypted.Rows.Count -ne 1 -or $decrypted.Rows[0].Matches -ne 1) { throw 'Encrypted test value did not match.' }
        } catch { throw 'Restored synthetic data could not be decrypted with the retained master-key password.' }
        finally { $password=$null;$query=$null;$secret=$null }
        $passed=$true
        return @{Database=$name;CheckDb='Passed';ReferenceRow='Passed';EncryptedValue='Passed';Kept=[bool]$Keep}
    } finally {
        if ($attempted -and (-not $Keep -or -not $passed)) {
            # Only this invocation's freshly allocated random database name is eligible.
            Invoke-CLSqlLocal $CL.Sql.Instance "IF DB_ID(N'$name') IS NOT NULL DROP DATABASE [$name]; SELECT 1 AS Ok" 300 | Out-Null
        }
    }
}
function New-CLHealthBackup {
    if ($CL.Sql.Instance -ne 'MSSQLSERVER' -or @($CL.Sql.Databases).Count -ne 1 -or $CL.Sql.Databases[0] -ne 'CloudLabHealth') { throw 'Native health backup requires the isolated default-instance profile.' }
    $project=([guid]$CL.ProjectId).ToString()
    $owner=Invoke-CLSqlLocal $CL.Sql.Instance "USE [CloudLabHealth]; SELECT CONVERT(nvarchar(128),value) AS Owner FROM sys.extended_properties WHERE class=0 AND name=N'CloudLabProject'"
    if ($owner.Rows.Count -ne 1 -or $owner.Rows[0].Owner -ne $project) { throw 'Backup database ownership mismatch.' }
    if ($CL.Sql.DriveLetter -notmatch '^[A-Za-z]$') { throw 'Invalid SQL data drive.' }
    $keyVersion=Initialize-CLHealthColumnEncryption
    $run=$CL.BackupSetId
    if ($run -notmatch '^[a-fA-F0-9-]{30,100}$') { throw 'Invalid backup run identifier.' }
    $directory="$($CL.Sql.DriveLetter):\LabBackup\Export\$run"
    if (Test-Path -LiteralPath $directory) { throw 'Backup directory already exists; never append/overwrite a backup.' }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $acl=Get-Acl -LiteralPath $directory
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('NT SERVICE\MSSQLSERVER','Modify','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $directory -AclObject $acl
    $backup=Join-Path $directory 'CloudLabHealth.bak'
    Invoke-CLSqlLocal $CL.Sql.Instance "BACKUP DATABASE [CloudLabHealth] TO DISK=N'$backup' WITH COPY_ONLY,CHECKSUM,COMPRESSION; SELECT 1 AS Ok" 1200 | Out-Null
    if ((Get-Item $backup).Length -gt ([long]$CL.Export.MaxArchiveMB*1MB-1MB)) { throw 'Backup exceeds bounded export size.' }
    $proof=Invoke-CLHealthRestore -BackupFile $backup -MasterKeySecretVersion $keyVersion
    @{Schema=1;MasterKeySecretVersion=$keyVersion;ProjectId=$project;ExportRunId=$CL.ExportRunId;Database='CloudLabHealth';BackupFile='CloudLabHealth.bak'
        Sha256=(Get-FileHash $backup -Algorithm SHA256).Hash;Restore=$proof;Utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 6 | Set-Content (Join-Path $directory 'backup-manifest.json') -Encoding utf8
    return $directory
}
