#requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^(latest|v\d+\.\d+\.\d+)$')][string]$Version='latest',[switch]$Refresh)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/HealthRelease.psm1" -Force
$directory = Join-Path $root '.local/releases'
$lockPath = Join-Path $directory 'health-release.json'
if ((Test-Path -LiteralPath $lockPath) -and -not $Refresh) {
    $existing = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    Assert-CLHealthRelease $existing
    if ($Version -ne 'latest' -and $existing.Tag -ne $Version) { throw 'A different release is locked. Use -Refresh to select another version.' }
    Write-Host "Reusing $($existing.Tag). No download, installation, or Azure operation."
    return
}
$repository = 'DanielP-1337/Infrastructure-Health-Benchmark'
$endpoint = if ($Version -eq 'latest') { 'latest' } else { "tags/$Version" }
$headers = @{ Accept='application/vnd.github+json'; 'User-Agent'='CloudLab-Azure' }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/$endpoint" -Headers $headers
$checksumAssets = @($release.assets | Where-Object { $_.name -ceq 'SHA256SUMS' -and $_.state -eq 'uploaded' })
$expectedChecksumUrl = "https://github.com/$repository/releases/download/$($release.tag_name)/SHA256SUMS"
if ($release.tag_name -cnotmatch '^v\d+\.\d+\.\d+$' -or $checksumAssets.Count -ne 1 -or $checksumAssets[0].browser_download_url -cne $expectedChecksumUrl) { throw 'Missing or unexpected checksum asset.' }
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$temp = Join-Path $directory ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $sumsPath = Join-Path $temp 'SHA256SUMS'
    Invoke-WebRequest -Uri $expectedChecksumUrl -Headers $headers -OutFile $sumsPath
    $sums = Get-Content -Raw -LiteralPath $sumsPath
    $lock = ConvertTo-CLHealthRelease $release ([string]$sums)
    $zip = Join-Path $temp $lock.Asset
    Invoke-WebRequest -Uri $lock.Url -Headers $headers -OutFile $zip
    if ((Get-Item -LiteralPath $zip).Length -ne $lock.Size -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $lock.Sha256) { throw 'Downloaded release ZIP failed size/SHA-256 verification.' }
    $json = Join-Path $temp 'lock.json'
    $lock | ConvertTo-Json | Set-Content -LiteralPath $json -Encoding utf8
    Move-Item -LiteralPath $zip -Destination (Join-Path $directory $lock.Asset) -Force
    Move-Item -LiteralPath $json -Destination $lockPath -Force
    Write-Host "Locked $($lock.Tag), SHA-256 $($lock.Sha256). Local download only; no installation or Azure operation."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
