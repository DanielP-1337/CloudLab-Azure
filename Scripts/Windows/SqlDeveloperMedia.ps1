# Shared by local preparation (PowerShell 7) and the guest (Windows PowerShell 5.1).
function Assert-CLSqlMediaLock {
    param($Media)
    if ($Media.Schema -ne 1 -or $Media.Edition -ne 'Developer' -or $Media.MajorVersion -ne 16) {
        throw 'Only SQL Server 2022 Developer media is supported by this provider.'
    }
    if ($Media.BootstrapUri -cne 'https://go.microsoft.com/fwlink/?LinkID=2214968') {
        throw 'Invalid Microsoft Developer download URI.'
    }
    foreach ($name in 'BootstrapSha256','IsoSha256','SetupSha256') {
        if ([string]$Media.$name -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid SQL media hash: $name" }
    }
    if ([long]$Media.IsoBytes -lt 100MB -or [long]$Media.IsoBytes -gt 10GB) { throw 'Invalid SQL ISO size.' }
}
function Assert-CLMicrosoftBinary {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
        throw 'A valid Microsoft Corporation signature is required.'
    }
}
function Get-CLSqlDeveloperIso {
    param([string]$Directory,[string]$BootstrapUri,$Expected)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $bootstrap = Join-Path $Directory 'SQL2022-SSEI-Dev.exe'
    if (-not (Test-Path -LiteralPath $bootstrap)) {
        $part = "$bootstrap.part"
        Invoke-WebRequest -UseBasicParsing -Uri $BootstrapUri -OutFile $part -ErrorAction Stop
        Assert-CLMicrosoftBinary $part
        if ($Expected -and (Get-FileHash $part -Algorithm SHA256).Hash -ne $Expected.BootstrapSha256) {
            throw 'Microsoft downloader changed; re-review media locally. No installer executed.'
        }
        Move-Item -LiteralPath $part -Destination $bootstrap
    }
    Assert-CLMicrosoftBinary $bootstrap
    if ($Expected -and (Get-FileHash $bootstrap -Algorithm SHA256).Hash -ne $Expected.BootstrapSha256) {
        throw 'SQL downloader checksum mismatch.'
    }
    $isos = @(Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File)
    if ($isos.Count -eq 0) {
        # Download only: never Basic, Custom, or Install on the workstation.
        $process = Start-Process -FilePath $bootstrap -ArgumentList @('/Action=Download','/Language=en-US',
            '/MediaType=ISO',"/MediaPath=`"$Directory`"",'/Quiet') -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "SQL media download failed: $($process.ExitCode)" }
        $isos = @(Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File)
    }
    if ($isos.Count -ne 1) { throw 'Expected exactly one SQL Developer ISO in the media directory.' }
    $iso = $isos[0]
    if ($iso.Length -lt 100MB -or $iso.Length -gt 10GB) { throw 'Unexpected SQL media size.' }
    $hash = (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Expected -and ($hash -ne $Expected.IsoSha256 -or $iso.Length -ne $Expected.IsoBytes)) {
        throw 'Full SQL ISO checksum/size mismatch. No setup executed.'
    }
    return [pscustomobject]@{ Path=$iso.FullName; Sha256=$hash; Bytes=$iso.Length
        BootstrapSha256=(Get-FileHash $bootstrap -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Mount-CLSqlDeveloperIso {
    param([string]$Path,[string]$ExpectedSetupSha256)
    # Only dismount images mounted by this operation.
    if ((Get-DiskImage -ImagePath $Path).Attached) { throw 'SQL ISO is already mounted. Dismount it before retrying.' }
    $disk = Mount-DiskImage -ImagePath $Path -Access ReadOnly -PassThru -ErrorAction Stop
    try {
        $volumes = @($disk | Get-Volume | Where-Object DriveLetter)
        if ($volumes.Count -ne 1) { throw 'Expected one mounted SQL media volume.' }
        $setup = "$($volumes[0].DriveLetter):\setup.exe"
        Assert-CLMicrosoftBinary $setup
        if ((Get-Item -LiteralPath $setup).VersionInfo.ProductMajorPart -ne 16) { throw 'Expected SQL Server 2022 setup.' }
        $hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ExpectedSetupSha256 -and $hash -ne $ExpectedSetupSha256) { throw 'Mounted SQL setup checksum mismatch.' }
        return [pscustomobject]@{ SetupPath=$setup; SetupSha256=$hash }
    } catch {
        Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
        throw
    }
}
