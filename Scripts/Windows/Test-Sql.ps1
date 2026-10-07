$service = if ($CL.Sql.Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$'+$CL.Sql.Instance }
if ((Get-Service $service).Status -ne 'Running') { throw 'SQL service is not running.' }
foreach ($db in $CL.Sql.Databases) {
    if ($db -notmatch '^[A-Za-z0-9_-]+$') { throw 'Unsupported database identifier.' }
    $result = Invoke-CLSqlLocal $CL.Sql.Instance "SELECT state_desc FROM sys.databases WHERE name=N'$db'"
    if ($result.Rows.Count -ne 1 -or $result.Rows[0].state_desc -ne 'ONLINE') { throw "Database is missing or not online: $db" }
}
if ((Get-Volume -DriveLetter $CL.Sql.DriveLetter).SizeRemaining -lt 10GB) { throw 'SQL data drive has less than 10 GiB free.' }
