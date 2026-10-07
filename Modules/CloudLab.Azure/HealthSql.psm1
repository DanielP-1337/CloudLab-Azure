$ErrorActionPreference='Stop'
function Assert-CLHealthSql {
    param($Config)
    if ($Config.Environment -ne 'sandbox' -or $Config.App.Provider -ne 'InfrastructureHealth' -or
        $Config.Sql.MajorVersion -ne 16 -or $Config.Sql.Instance -ne 'MSSQLSERVER') {
        throw 'Health SQL adapter requires a sandbox, InfrastructureHealth, and SQL 2022 default instance.'
    }
    if (-not $Config.ContainsKey('HealthSql') -or -not $Config.HealthSql.Enabled) { throw 'Run Initialize-HealthSql.ps1 first.' }
    if ($Config.Sql.Name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,14}$') { throw 'Invalid SQL computer name.' }
    if (@($Config.Sql.Databases).Count -ne 1 -or $Config.Sql.Databases[0] -ne 'CloudLabHealth') { throw 'Expected the isolated CloudLabHealth test database.' }
}
function Read-CLHealthSql {
    param($Config,[string]$ProjectRoot)
    Assert-CLHealthSql $Config
    $dir=Join-Path $ProjectRoot '.local/pki/sql-health'
    $m=Get-Content -Raw (Join-Path $dir 'manifest.json') | ConvertFrom-Json
    if ($m.Schema -ne 1 -or $m.ProjectId -ne $Config.ProjectId -or $m.ComputerName -ne $Config.Sql.Name) { throw 'SQL PKI project/host mismatch.' }
    $root=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes((Join-Path $dir 'root.cer')))
    $leaf=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes((Join-Path $dir 'server.cer')))
    $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        if ($root.Thumbprint -ne $m.RootThumbprint -or $leaf.Thumbprint -ne $m.ServerThumbprint -or
            $leaf.NotAfter -lt (Get-Date).AddDays(7) -or -not $leaf.MatchesHostname('sql.cloudlab.test',$false,$false)) { throw 'SQL certificate validation failed.' }
        $eku=@($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
        if ($eku.Count -ne 1 -or '1.3.6.1.5.5.7.3.1' -notin $eku[0].EnhancedKeyUsages.Value) { throw 'SQL certificate lacks Server Authentication EKU.' }
        $chain.ChainPolicy.TrustMode=[Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        [void]$chain.ChainPolicy.CustomTrustStore.Add($root)
        $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        if (-not $chain.Build($leaf)) { throw 'SQL certificate chain invalid.' }
        $driver=Get-Content -Raw "$ProjectRoot/.local/releases/health-odbc.json" | ConvertFrom-Json
        if ($driver.Uri -cne 'https://go.microsoft.com/fwlink/?clcid=0x409&linkid=2378279' -or $driver.Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid ODBC driver lock.' }
        return @{Enabled=$true;Database='CloudLabHealth';Login='cloudlab_health';Dsn='HealthCheck';HostName='sql.cloudlab.test'
            PasswordSecret='health-sql-password';CertificateSecret='sql-health-tls';Driver=$driver
            RootDerBase64=[Convert]::ToBase64String($root.RawData);RootThumbprint=$root.Thumbprint;ServerThumbprint=$leaf.Thumbprint}
    } finally { $chain.Dispose();$root.Dispose();$leaf.Dispose() }
}
function Set-CLHealthSqlConfigText {
    param([string]$Text)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Invalid configuration syntax.' }
    $top=$ast.Find({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)
    $sqlPair=@($top.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq 'Sql' })
    if ($sqlPair.Count -ne 1) { throw 'Expected one Sql block.' }
    $sql=$sqlPair[0].Item2.Find({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)
    $db=@($sql.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq 'Databases' })
    if ($db.Count -ne 1) { throw 'Expected Sql.Databases.' }
    $h=@($top.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq 'HealthSql' })
    if ($h.Count -gt 1) { throw 'Duplicate HealthSql block.' }
    $e=$db[0].Item2.Extent
    $edits=@(@{Start=$e.StartOffset;Length=$e.EndOffset-$e.StartOffset;Text="@('CloudLabHealth')"})
    if ($h.Count) {
        $e=$h[0].Item2.Extent
        $edits+=@{Start=$e.StartOffset;Length=$e.EndOffset-$e.StartOffset;Text='@{ Enabled = $true }'}
    } else {
        $nl=if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $edits+=@{Start=$top.Extent.StartOffset+2;Length=0;Text=$nl+'    HealthSql = @{ Enabled = $true }'+$nl}
    }
    foreach ($e in $edits | Sort-Object Start -Descending) { $Text=$Text.Remove($e.Start,$e.Length).Insert($e.Start,$e.Text) }
    return $Text
}
Export-ModuleMember -Function *-CL*
