$developer = $CL.Sql.PSObject.Properties['MediaProvider'] -and $CL.Sql.MediaProvider -eq 'Developer2022'
if ($developer) { Assert-CLSqlMediaLock $CL.Sql.DeveloperMedia }
Initialize-CLDataDisk -Letter $CL.Sql.DriveLetter -ExpectedGB $CL.Sql.DiskGB
if ($CL.Sql.Instance -notmatch '^[A-Za-z][A-Za-z0-9_]{0,15}$') { throw 'Invalid SQL instance name.' }
if ($CL.Sql.Collation -match 'REPLACE' -or $CL.Sql.Collation -notmatch '^[A-Za-z0-9_]+$') { throw 'Set exact source SQL collation.' }
$serviceName = if ($CL.Sql.Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { 'MSSQL$'+$CL.Sql.Instance }
$serviceAccount = 'NT Service\'+$serviceName
$root = "$($CL.Sql.DriveLetter):\SQL"
foreach ($folder in 'Data','Log','TempDB','Backup') { New-Item -ItemType Directory -Path "$root\$folder" -Force | Out-Null }
if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
    $mountedIso = $null
    $setupPath = $CL.Sql.SetupPath
    if ($developer) {
        $media = $CL.Sql.DeveloperMedia
        $directory = Join-Path $env:ProgramData ("CloudLab\SqlMedia\" + $media.IsoSha256)
        $iso = Get-CLSqlDeveloperIso -Directory $directory -BootstrapUri $media.BootstrapUri -Expected $media
        $mounted = Mount-CLSqlDeveloperIso -Path $iso.Path -ExpectedSetupSha256 $media.SetupSha256
        $mountedIso = $iso.Path
        $setupPath = $mounted.SetupPath
    } else {
        if (-not (Test-Path -LiteralPath $setupPath)) { throw 'Stage the licensed SQL media at Sql.SetupPath first.' }
        if ((Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash -ne $CL.Sql.SetupSha256) { throw 'SQL setup checksum mismatch.' }
    }
    try {
        $arguments = @('/Q','/ACTION=Install','/FEATURES=SQLENGINE','/IACCEPTSQLSERVERLICENSETERMS',
            "/INSTANCENAME=$($CL.Sql.Instance)","/SQLCOLLATION=$($CL.Sql.Collation)",
            '/SQLSYSADMINACCOUNTS="NT AUTHORITY\SYSTEM"',"/SQLSVCACCOUNT=`"$serviceAccount`"",'/SQLSVCSTARTUPTYPE=Automatic',
            "/SQLUSERDBDIR=`"$root\Data`"","/SQLUSERDBLOGDIR=`"$root\Log`"","/SQLTEMPDBDIR=`"$root\TempDB`"", "/SQLBACKUPDIR=`"$root\Backup`"",'/TCPENABLED=1','/NPENABLED=0','/UPDATEENABLED=False')
        $process = Start-Process -FilePath $setupPath -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -eq 3010) { throw 'SQL installed; reboot the VM, then rerun deployment.' }
        if ($process.ExitCode -ne 0) { throw "SQL setup failed: exit code $($process.ExitCode)" }
    } finally {
        if ($mountedIso) { Dismount-DiskImage -ImagePath $mountedIso | Out-Null }
    }
}
# Refuse to convert a pre-existing licensed/evaluation instance implicitly.
if ($developer) {
    $edition = Invoke-CLSqlLocal $CL.Sql.Instance "SELECT CONVERT(int,SERVERPROPERTY('EditionID')) AS EditionId, CONVERT(int,SERVERPROPERTY('ProductMajorVersion')) AS MajorVersion"
    if ($edition.Rows[0].EditionId -ne -2117995310 -or $edition.Rows[0].MajorVersion -ne 16) {
        throw 'Expected SQL Server 2022 Developer. No automatic edition conversion is performed.'
    }
}
$instances = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
$instanceId = $instances.PSObject.Properties[$CL.Sql.Instance].Value
if (-not $instanceId) { throw 'SQL instance registry mapping missing.' }
$tcp = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
Set-ItemProperty $tcp -Name Enabled -Value 1
Set-ItemProperty "$tcp\IPAll" -Name TcpDynamicPorts -Value ''
Set-ItemProperty "$tcp\IPAll" -Name TcpPort -Value ([string]$CL.Sql.Port)
# Only a single explicit source is allowed at Windows Firewall and NSG.
Get-NetFirewallRule -DisplayName 'CloudLab SQL' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'CloudLab SQL' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $CL.Sql.Port -RemoteAddress $CL.App.Ip | Out-Null
Restart-Service -Name $serviceName
$version = Invoke-CLSqlLocal $CL.Sql.Instance "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')) AS MajorVersion, CONVERT(nvarchar(128),SERVERPROPERTY('Collation')) AS Collation"
if ($version.Rows[0].MajorVersion -ne $CL.Sql.MajorVersion -or $version.Rows[0].Collation -ne $CL.Sql.Collation) { throw 'SQL version/collation differs from approved source.' }
$memory = [int]$CL.Sql.MaxMemoryMB
Invoke-CLSqlLocal $CL.Sql.Instance "EXEC sp_configure 'show advanced options',1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)',$memory; RECONFIGURE; SELECT 1 AS Ok;" | Out-Null
# No automatic database creation/migration, recovery-model changes or password guesses.
