$ErrorActionPreference = 'Stop'
function Assert-CLHealthRelease {
    param([Parameter(Mandatory)]$Release)
    $repository = 'DanielP-1337/Infrastructure-Health-Benchmark'
    if ($Release.Schema -ne 1 -or $Release.Repository -cne $repository) { throw 'Unsupported health release lock.' }
    if ($Release.Tag -cnotmatch '^v\d+\.\d+\.\d+$') { throw 'Expected a stable version tag.' }
    $version = $Release.Tag.Substring(1)
    $name = "Infrastructure-Health-Benchmark-$version.zip"
    $url = "https://github.com/$repository/releases/download/$($Release.Tag)/$name"
    if ($Release.Asset -cne $name -or $Release.Url -cne $url) { throw 'Unexpected health release asset or URL.' }
    if ($Release.Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid health release SHA-256.' }
    if ($Release.Size -lt 1 -or $Release.Size -gt 50MB) { throw 'Health release must be between 1 byte and 50 MiB.' }
}
function ConvertTo-CLHealthRelease {
    param([Parameter(Mandatory)]$Metadata,[Parameter(Mandatory)][string]$Checksums)
    if ($Metadata.draft -or $Metadata.prerelease) { throw 'Drafts and prereleases are not accepted.' }
    if ($Metadata.tag_name -cnotmatch '^v\d+\.\d+\.\d+$') { throw 'Expected a stable version tag.' }
    $name = "Infrastructure-Health-Benchmark-$($Metadata.tag_name.Substring(1)).zip"
    $assets = @($Metadata.assets | Where-Object { $_.name -ceq $name -and $_.state -eq 'uploaded' })
    if ($assets.Count -ne 1) { throw 'Expected exactly one uploaded release ZIP.' }
    $lines = @($Checksums -split '\r?\n' | Where-Object { $_.Trim() })
    $hashes = @()
    foreach ($line in $lines) {
        if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$' -and $Matches[2] -ceq $name) { $hashes += $Matches[1].ToLowerInvariant() }
    }
    if ($hashes.Count -ne 1) { throw 'Expected exactly one matching SHA256SUMS entry.' }
    $asset = $assets[0]
    if ($asset.digest -cne "sha256:$($hashes[0])") { throw 'GitHub asset digest and SHA256SUMS disagree.' }
    $lock = [ordered]@{ Schema=1; Repository='DanielP-1337/Infrastructure-Health-Benchmark'; Tag=$Metadata.tag_name; Asset=$name; Url=$asset.browser_download_url; Sha256=$hashes[0]; Size=[long]$asset.size }
    Assert-CLHealthRelease $lock
    return $lock
}
Export-ModuleMember -Function Assert-CLHealthRelease,ConvertTo-CLHealthRelease
