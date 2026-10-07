#requires -version 5.1
[CmdletBinding()]
param([string]$DsnName='HealthCheck',[string]$ConfigPath,[string]$OutputPath,[switch]$TestTlsRejection)
$ErrorActionPreference='Stop'
$result=[ordered]@{available=$false;bitness=$(if ([IntPtr]::Size -eq 8) {'64-bit'} else {'32-bit'});dsn=$DsnName
    imagePath=$null;serverName=$null;databaseName=$null;authentication='SQL login / verified TLS'
    runAs=[Security.Principal.WindowsIdentity]::GetCurrent().Name;error=$null}
$connection=$null;$command=$null;$password=$null;$builder=$null
try {
    $settings=Get-Content -Raw "$PSScriptRoot/CloudLabSql.json" | ConvertFrom-Json
    if ($DsnName -ne 'HealthCheck' -or $settings.Database -ne 'CloudLabHealth' -or $settings.HostName -ne 'sql.cloudlab.test') { throw 'Profile mismatch.' }
    $token=Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
    $password=(Invoke-RestMethod -Headers @{Authorization="Bearer $($token.access_token)"} -Uri "https://$($settings.Vault).vault.azure.net/secrets/health-sql-password?api-version=7.4").value
    $builder=New-Object System.Data.Odbc.OdbcConnectionStringBuilder
    $builder['DSN']='HealthCheck';$builder['UID']='cloudlab_health';$builder['PWD']=$password
    $builder['Server']="tcp:$($settings.Address),$($settings.Port)";$builder['Database']='CloudLabHealth'
    $builder['Trusted_Connection']='No';$builder['Encrypt']='Yes';$builder['TrustServerCertificate']='No'
    $builder['HostnameInCertificate']=$(if ($TestTlsRejection) {'wrong-name.cloudlab.invalid'} else {'sql.cloudlab.test'})
    $connection=New-Object System.Data.Odbc.OdbcConnection($builder.ConnectionString)
    $connection.Open()
    if ($TestTlsRejection) { throw 'Wrong certificate name was accepted.' }
    $command=$connection.CreateCommand();$command.CommandTimeout=10
    $command.CommandText='EXEC dbo.ReadHealth;'
    $reader=$command.ExecuteReader()
    try {
        if (-not $reader.Read()) { throw 'No synthetic row returned.' }
        $result.serverName=[string]$reader.GetValue(0);$result.databaseName=[string]$reader.GetValue(1);$result.imagePath=[string]$reader.GetValue(2)
    } finally { $reader.Dispose() }
    $command.CommandText="SELECT IS_SRVROLEMEMBER('sysadmin'),IS_MEMBER('db_owner'),HAS_PERMS_BY_NAME('dbo.HealthSample','OBJECT','INSERT'),HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','CREATE TABLE');"
    $reader=$command.ExecuteReader()
    try {
        if (-not $reader.Read()) { throw 'Permission verification failed.' }
        for ($i=0;$i -lt 4;$i++) { if ($reader.IsDBNull($i) -or [int]$reader.GetValue($i) -ne 0) { throw 'Excessive health login permissions.' } }
    } finally { $reader.Dispose() }
    $result.available=$true
} catch [System.Data.Odbc.OdbcException] {
    if ($TestTlsRejection) {
        $nameErrors=@($_.Exception.Errors | Where-Object { $_.NativeError -eq -2146893022 -or $_.Message -match 'target principal name is incorrect|certificate.*name.*mismatch' })
        if ($nameErrors.Count) { $result.available=$true } else { $result.error='Negative TLS test failed for an unexpected reason.' }
    } else { $result.error='SQL connection/query failed. Review local SQL, ODBC, TLS and Key Vault configuration.' }
} catch { $result.error='SQL probe failed validation. No credentials or raw exception are included.' }
finally {
    if ($command) { $command.Dispose() }
    if ($connection) { $connection.Dispose() }
    if ($builder) { $builder.Clear() }
    $password=$null;$token=$null
}
$json=$result | ConvertTo-Json -Compress
if ($OutputPath) { [IO.File]::WriteAllText($OutputPath,$json,[Text.UTF8Encoding]::new($false)) }
else { [Console]::Out.Write($json) }
# The existing health engine consumes JSON; it does not use the child's exit code.
if ($result.available) { exit 0 } else { exit 1 }
