#requires -Version 7.4
# Offline, ephemeral test certificates; no OS trust, hosts, network, or Azure changes.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/LabTls.psm1" -Force
function Assert-Throws([scriptblock]$Block) {
    $failed=$false
    try { & $Block | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Expected a guard failure.' }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-tls-'+[guid]::NewGuid().ToString('N'))
$certs=[Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
try {
    $dir=Join-Path $temp '.local/pki/lab'
    $password=ConvertTo-SecureString 'Only-for-offline-tests-123!' -AsPlainText -Force
    New-CLLabCertificateFiles $dir 'offline-project' $password
    $config=@{ProjectId='offline-project'; AppHost='app.cloudlab.test'; AuthHost='auth.cloudlab.test'; BackendHost='backend.cloudlab.test'}
    $tls=Read-CLLabTls $config $temp
    $certs.Import([IO.File]::ReadAllBytes("$dir/server.pfx"),'Only-for-offline-tests-123!',[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $private=@($certs | Where-Object HasPrivateKey)
    if ($private.Count -ne 1 -or $private[0].Thumbprint -ne $tls.ServerThumbprint) { throw 'PFX must contain only the server private key.' }
    $roots=@($certs | Where-Object Thumbprint -eq $tls.RootThumbprint)
    if ($roots.Count -ne 1 -or $roots[0].HasPrivateKey) { throw 'Root private key leaked into server PFX.' }
    Assert-Throws { New-CLLabCertificateFiles $dir 'offline-project' $password }
    $config.AuthHost='different.cloudlab.test'
    Assert-Throws { Read-CLLabTls $config $temp }
    $config.AuthHost='auth.cloudlab.test'; $config.ProjectId='another-project'
    Assert-Throws { Read-CLLabTls $config $temp }
    $config.ProjectId='offline-project'
    [IO.File]::WriteAllBytes("$dir/server.cer",[IO.File]::ReadAllBytes("$dir/root-ca.cer"))
    Assert-Throws { Read-CLLabTls $config $temp }
    $text="@{`n AppHost='old'; AuthHost='old'; BackendHost='old'; Keep='unchanged'`n}"
    $updated=Set-CLLabConfigText $text 'kv-cloudlab-test' 'web-tls'
    $file=Join-Path $temp 'test.psd1'; [IO.File]::WriteAllText($file,$updated)
    $parsed=Import-PowerShellDataFile $file
    if ($parsed.Keep -ne 'unchanged' -or -not $parsed.LabTlsEnabled -or $parsed.AuthHost -ne 'auth.cloudlab.test') { throw 'Local config migration failed.' }
    if ((Set-CLLabConfigText $updated 'kv-cloudlab-test' 'web-tls') -ne $updated) { throw 'Config migration is not idempotent.' }
    foreach ($nl in @("`n","`r`n")) {
        $hosts="127.0.0.1 localhost${nl}192.0.2.8 unrelated.test${nl}"
        $mapped=Update-CLLabHostsText $hosts 'offline-project' '192.0.2.10'
        if ((Update-CLLabHostsText $mapped 'offline-project' '192.0.2.10') -ne $mapped) { throw 'Hosts update is not idempotent.' }
        if ((Update-CLLabHostsText $mapped 'offline-project' '' -Remove) -ne $hosts) { throw 'Hosts cleanup changed unrelated content.' }
        Assert-Throws { Update-CLLabHostsText ($hosts+'192.0.2.11 app.cloudlab.test'+$nl) 'offline-project' '192.0.2.10' }
    }
    Assert-Throws { Update-CLLabHostsText '' 'offline-project' '127.0.0.1' }
    Write-Host 'Offline lab certificate chain, private-key isolation, config, and hosts tests passed.'
} finally {
    foreach ($cert in $certs) { $cert.Dispose() }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
