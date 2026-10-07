$folder = Join-Path $CL.Backup.SqlPath $CL.BackupSetId
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$serviceName = if ($CL.Sql.Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$'+$CL.Sql.Instance }
$acl = Get-Acl $folder
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT SERVICE\$serviceName",'Modify','ContainerInherit,ObjectInherit','None','Allow')))
Set-Acl $folder $acl
foreach ($db in $CL.Sql.Databases) {
    if ($db -notmatch '^[A-Za-z0-9_-]+$') { throw 'Database names must be simple identifiers for this backup implementation.' }
    $file = Join-Path $folder "$db.bak"
    $literal = $file.Replace("'","''")
    Invoke-CLSqlLocal $CL.Sql.Instance "BACKUP DATABASE [$db] TO DISK=N'$literal' WITH COPY_ONLY, CHECKSUM; RESTORE VERIFYONLY FROM DISK=N'$literal' WITH CHECKSUM; SELECT 1 AS Ok;" 14400 | Out-Null
}
# No INIT/FORMAT/REPLACE and no destructive local retention cleanup.
$CL | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $folder 'backup-config.json') -Encoding UTF8
