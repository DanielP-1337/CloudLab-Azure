#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this local preparation on Windows.' }
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/Windows/SqlDeveloperMedia.ps1"
$lockPath = Join-Path $root '.local/releases/sql-developer.json'
$mediaDir = Join-Path $root '.local/media/sql2022-developer'
if (Test-Path -LiteralPath $lockPath) {
    $existing = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    Assert-CLSqlMediaLock $existing
    Write-Output 'Reusing approved SQL Developer media lock. No download, installation, or Azure operation.'
    return
}
if (-not $PSCmdlet.ShouldProcess($mediaDir,'Download Microsoft SQL 2022 Developer ISO and record local checksums; no SQL installation')) { return }
# Microsoft replacement-download link reported by the SQL 2022 Developer installer.
$uri = 'https://go.microsoft.com/fwlink/?LinkID=2214968'
$iso = Get-CLSqlDeveloperIso -Directory $mediaDir -BootstrapUri $uri
$mounted = Mount-CLSqlDeveloperIso -Path $iso.Path
try {
    $lock = [pscustomobject]@{ Schema=1; Edition='Developer'; MajorVersion=16; BootstrapUri=$uri
        BootstrapSha256=$iso.BootstrapSha256; IsoSha256=$iso.Sha256; IsoBytes=$iso.Bytes
        SetupSha256=$mounted.SetupSha256 }
    Assert-CLSqlMediaLock $lock
    New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
    $lock | ConvertTo-Json | Set-Content -LiteralPath "$lockPath.tmp" -Encoding utf8
    Move-Item -LiteralPath "$lockPath.tmp" -Destination $lockPath
} finally { Dismount-DiskImage -ImagePath $iso.Path | Out-Null }
Write-Output 'SQL Developer media prepared locally. No SQL installation or Azure operation.'
$lock | Format-List Edition,MajorVersion,IsoBytes,IsoSha256,SetupSha256
