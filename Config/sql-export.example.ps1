# Copy to the private SQL VM, configure Export.SqlPreparePath and its SHA256 locally.
# Native COPY_ONLY export; does not change the recovery model or log-backup chain.
param([Parameter(Mandatory)]$Configuration)
$ErrorActionPreference='Stop'
$folder=$Configuration.Export.SqlPaths[0]
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$service=if ($Configuration.Sql.Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$'+$Configuration.Sql.Instance }
$acl=Get-Acl $folder
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new("NT SERVICE\$service",'Modify','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl $folder $acl
$instance=if ($Configuration.Sql.Instance -eq 'MSSQLSERVER') { '.' } else { '.\'+$Configuration.Sql.Instance }
$conn=[Data.SqlClient.SqlConnection]::new("Server=lpc:$instance;Integrated Security=true;Database=master")
try {
 $conn.Open()
 foreach ($db in $Configuration.Sql.Databases) {
  if ($db -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Unsupported database name.' }
  $path=Join-Path $folder ($db+'-'+[guid]::NewGuid().ToString('N')+'.bak')
  $literal=$path.Replace("'","''")
  $cmd=$conn.CreateCommand();$cmd.CommandTimeout=3600
  $cmd.CommandText="BACKUP DATABASE [$db] TO DISK=N'$literal' WITH COPY_ONLY,CHECKSUM; RESTORE VERIFYONLY FROM DISK=N'$literal' WITH CHECKSUM;"
  $cmd.ExecuteNonQuery() | Out-Null
 }
} finally { $conn.Dispose() }
