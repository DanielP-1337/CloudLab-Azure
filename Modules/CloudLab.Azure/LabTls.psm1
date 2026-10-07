# Local lab PKI helpers. Certificate generation requires PowerShell 7 / modern .NET.
$ErrorActionPreference = 'Stop'
function Get-CLLabNames {
    @('app.cloudlab.test','auth.cloudlab.test','backend.cloudlab.test')
}
function New-CLLabCertificateFiles {
    param([string]$Directory,[string]$ProjectId,[Security.SecureString]$Password)
    if ($Password.Length -lt 16) { throw 'Use a PFX password with at least 16 characters.' }
    if (Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue) { throw 'PKI directory must be empty. Existing certificates are never replaced automatically.' }
    $rootKey = [Security.Cryptography.RSA]::Create(3072)
    $leafKey = [Security.Cryptography.RSA]::Create(3072)
    $rootCert=$null; $leaf=$null; $signed=$null; $pointer=[IntPtr]::Zero
    try {
        $hash=[Security.Cryptography.HashAlgorithmName]::SHA256
        $padding=[Security.Cryptography.RSASignaturePadding]::Pkcs1
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=CloudLab Test Root CA',$rootKey,$hash,$padding)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$true,0,$true))
        $usage=[Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usage,$true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey,$false))
        $start=[DateTimeOffset]::UtcNow.AddMinutes(-10)
        $rootCert=$request.CreateSelfSigned($start,$start.AddYears(1))
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=app.cloudlab.test',$leafKey,$hash,$padding)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
        $usage=[Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($usage,$true))
        $oids=[Security.Cryptography.OidCollection]::new()
        [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
        $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        foreach ($name in Get-CLLabNames) { $san.AddDnsName($name) }
        $request.CertificateExtensions.Add($san.Build())
        $serial=[byte[]]::new(16); $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($serial) } finally { $rng.Dispose() }
        $serial[0]=1
        $signed=$request.Create($rootCert,$start,$start.AddDays(90),$serial)
        $leaf=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($signed,$leafKey)
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $collection=[Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        [void]$collection.Add($leaf)
        # Include the public root in the server chain, never its private key.
        $publicRoot=[Security.Cryptography.X509Certificates.X509Certificate2]::new($rootCert.RawData)
        try { [void]$collection.Add($publicRoot)
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
            [IO.File]::WriteAllBytes((Join-Path $Directory 'server.pfx'),$collection.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,$plain))
        } finally { $plain=$null; $publicRoot.Dispose() }
        [IO.File]::WriteAllBytes((Join-Path $Directory 'root-ca.cer'),$rootCert.RawData)
        [IO.File]::WriteAllBytes((Join-Path $Directory 'server.cer'),$leaf.RawData)
        [IO.File]::WriteAllText((Join-Path $Directory 'root-ca.pem'),$rootCert.ExportCertificatePem())
        [ordered]@{Schema=1; ProjectId=$ProjectId; RootThumbprint=$rootCert.Thumbprint; ServerThumbprint=$leaf.Thumbprint; Hosts=@(Get-CLLabNames); ExpiresUtc=$leaf.NotAfter.ToUniversalTime().ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'manifest.json') -Encoding utf8
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        foreach ($cert in @($leaf,$signed,$rootCert)) { if ($cert) { $cert.Dispose() } }
        $leafKey.Dispose(); $rootKey.Dispose()
    }
}
function Read-CLLabTls {
    param($Config,[string]$ProjectRoot)
    $dir=Join-Path $ProjectRoot '.local/pki/lab'
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $dir 'manifest.json') | ConvertFrom-Json
    if ($manifest.Schema -ne 1 -or $manifest.ProjectId -ne $Config.ProjectId) { throw 'Lab certificate project mismatch.' }
    $names=@(Get-CLLabNames)
    if (($manifest.Hosts -join '|') -cne ($names -join '|')) { throw 'Unexpected lab certificate names.' }
    $i=0
    foreach ($key in 'AppHost','AuthHost','BackendHost') {
        if ($Config[$key] -cne $names[$i++]) { throw "Lab TLS requires the configured .test name for $key." }
    }
    $rootCert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes((Join-Path $dir 'root-ca.cer')))
    $leaf=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes((Join-Path $dir 'server.cer')))
    $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        if ($rootCert.Thumbprint -ne $manifest.RootThumbprint -or $leaf.Thumbprint -ne $manifest.ServerThumbprint) { throw 'Lab certificate thumbprint mismatch.' }
        $constraints=@($rootCert.Extensions | Where-Object Oid -ne $null | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
        if ($constraints.Count -ne 1 -or -not $constraints[0].CertificateAuthority) { throw 'Lab root is not a CA.' }
        if ($leaf.NotAfter -lt (Get-Date).AddDays(7)) { throw 'Lab server certificate expires in less than seven days.' }
        $chain.ChainPolicy.TrustMode=[Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        [void]$chain.ChainPolicy.CustomTrustStore.Add($rootCert)
        $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        if (-not $chain.Build($leaf)) { throw 'Lab certificate chain validation failed.' }
        foreach ($name in $names) { if (-not $leaf.MatchesHostname($name,$false,$false)) { throw 'Lab SAN mismatch.' } }
        return @{RootDerBase64=[Convert]::ToBase64String($rootCert.RawData); RootThumbprint=$rootCert.Thumbprint; ServerThumbprint=$leaf.Thumbprint}
    } finally { $chain.Dispose(); $leaf.Dispose(); $rootCert.Dispose() }
}
function Set-CLLabConfigText {
    param([string]$Text,[string]$Vault,[string]$Secret)
    if ($Vault -match 'REPLACE' -or $Secret -match 'REPLACE' -or $Vault -notmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$' -or $Secret -notmatch '^[a-zA-Z0-9-]+$') { throw 'Set valid vault and certificate secret names first.' }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Configuration has syntax errors.' }
    $top=$ast.Find({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)
    if (-not $top) { throw 'Missing configuration hashtable.' }
    $changes=@{AppHost="'app.cloudlab.test'";AuthHost="'auth.cloudlab.test'";BackendHost="'backend.cloudlab.test'";LabTlsEnabled='$true';GatewayCertificateSecretUri="'https://$Vault.vault.azure.net/secrets/$Secret'"}
    $edits=@(); $inserts=@(); $nl=if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($key in $changes.Keys) {
        $pairs=@($top.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq $key })
        if ($pairs.Count -gt 1) { throw 'Duplicate configuration key.' }
        if ($pairs.Count -eq 1) {
            $e=$pairs[0].Item2.Extent; $edits+=@{Start=$e.StartOffset;Length=$e.EndOffset-$e.StartOffset;Text=$changes[$key]}
        } else { $inserts+="    $key = $($changes[$key])" }
    }
    if ($inserts.Count) { $edits+=@{Start=$top.Extent.StartOffset+2;Length=0;Text=$nl+($inserts -join $nl)+$nl} }
    foreach ($e in $edits | Sort-Object Start -Descending) { $Text=$Text.Remove($e.Start,$e.Length).Insert($e.Start,$e.Text) }
    return $Text
}
Export-ModuleMember -Function *-CL*
function Update-CLLabHostsText {
    param([string]$Text,[string]$ProjectId,[string]$Address,[switch]$Remove)
    if ($ProjectId -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid project identifier for hosts marker.' }
    $begin="# CloudLab $ProjectId BEGIN"; $end="# CloudLab $ProjectId END"
    $starts=[regex]::Matches($Text,'(?m)^'+[regex]::Escape($begin)+'\r?$').Count
    $ends=[regex]::Matches($Text,'(?m)^'+[regex]::Escape($end)+'\r?$').Count
    if ($starts -ne $ends -or $starts -gt 1) { throw 'Ambiguous CloudLab hosts block; review manually.' }
    $pattern='(?ms)^'+[regex]::Escape($begin)+'\r?\n.*?^'+[regex]::Escape($end)+'(?:\r?\n|$)'
    $clean=[regex]::Replace($Text,$pattern,'')
    if ($starts -eq 1 -and $clean -eq $Text) { throw 'Malformed CloudLab hosts block.' }
    if ($Remove) { return $clean }
    $ip=$null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([Net.IPAddress]::Any)) { throw 'Supply the actual gateway IPv4 address.' }
    foreach ($line in $clean -split '\r?\n') {
        $parts=@(($line -split '#',2)[0].Trim() -split '\s+')
        foreach ($hostName in @('app.cloudlab.test','auth.cloudlab.test')) {
            if ($parts -contains $hostName) { throw 'Conflicting .test entry outside this project hosts block.' }
        }
    }
    $nl=if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($clean.Length -and -not $clean.EndsWith("`n")) { $clean+=$nl }
    return $clean+$begin+$nl+"$Address app.cloudlab.test auth.cloudlab.test"+$nl+$end+$nl
}
Export-ModuleMember -Function *-CL*
