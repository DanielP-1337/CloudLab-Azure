# Offline: no GitHub request, installation, or Azure operation.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/HealthRelease.psm1" -Force
function Assert-Throws([scriptblock]$Block) {
    $failed = $false
    try { & $Block | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected rejection.' }
}
$hash = 'a' * 64
$name = 'Infrastructure-Health-Benchmark-0.1.8.zip'
$url = "https://github.com/DanielP-1337/Infrastructure-Health-Benchmark/releases/download/v0.1.8/$name"
$asset = [pscustomobject]@{name=$name; state='uploaded'; size=100; digest="sha256:$hash"; browser_download_url=$url}
$metadata = [pscustomobject]@{draft=$false; prerelease=$false; tag_name='v0.1.8'; assets=@($asset)}
$lock = ConvertTo-CLHealthRelease $metadata "$hash  $name`n"
Assert-CLHealthRelease ($lock | ConvertTo-Json | ConvertFrom-Json)
$metadata.draft=$true
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  $name" }
$metadata.draft=$false; $metadata.prerelease=$true
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  $name" }
$metadata.prerelease=$false
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  other.zip" }
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  $name`n$hash  $name" }
$asset.digest='sha256:' + ('b'*64)
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  $name" }
$asset.digest="sha256:$hash"; $asset.browser_download_url='https://example.invalid/package.zip'
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  $name" }
$asset.browser_download_url=$url; $metadata.assets=@($asset,$asset)
Assert-Throws { ConvertTo-CLHealthRelease $metadata "$hash  $name" }
$lock.Size=51MB
Assert-Throws { Assert-CLHealthRelease $lock }
$lock.Size=100; $lock.Tag='v0.1.8/../../other'
Assert-Throws { Assert-CLHealthRelease $lock }

# Exercise the production payload composer with a mocked Azure boundary.
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Sql.psm1" -Force
function global:Invoke-CLGuest {
    param($Config,$VM,$Script,$OS)
    if ($Script -notmatch 'function Install-CLHealthApplication' -or $Script -notmatch 'Install-InfrastructureHealth.ps1') { throw 'Missing guest installer.' }
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseInput($Script,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw 'Composed guest payload does not parse.' }
}
try {
    Invoke-CLWindowsScript @{ProjectId='test-project'; App=@{Provider='InfrastructureHealth'}} $root 'Install-Application.ps1' 'offline-vm'
} finally { Remove-Item Function:\Invoke-CLGuest }
Write-Host 'Offline release selection, integrity guards, and guest payload checks passed.'
