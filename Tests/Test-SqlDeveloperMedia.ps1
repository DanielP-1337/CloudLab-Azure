# Offline behavior checks. No network, installation, or Azure operations.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. "$root/Scripts/Windows/SqlDeveloperMedia.ps1"
function Assert-Throws([scriptblock]$Block,[string]$Message) {
    try { & $Block | Out-Null } catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        return
    }
    throw 'Expected rejection did not occur.'
}
$uri = 'https://go.microsoft.com/fwlink/?LinkID=2214968'
$lock = [pscustomobject]@{ Schema=1; Edition='Developer'; MajorVersion=16; BootstrapUri=$uri
    BootstrapSha256=('a'*64); IsoSha256=('b'*64); SetupSha256=('c'*64); IsoBytes=101MB }
Assert-CLSqlMediaLock $lock
foreach ($edition in 'Express','Enterprise','Evaluation') {
    $lock.Edition=$edition
    Assert-Throws { Assert-CLSqlMediaLock $lock } '*Only SQL Server*'
}
$lock.Edition='Developer'; $lock.MajorVersion=17
Assert-Throws { Assert-CLSqlMediaLock $lock } '*Only SQL Server*'
$lock.MajorVersion=16
foreach ($bad in 'http://download.microsoft.com/SQL2022-SSEI-Dev.exe',
    'https://download.microsoft.com.example.invalid/SQL2022-SSEI-Dev.exe',
    'https://download.microsoft.com/SQL2022-SSEI-Dev.exe?token=x',
    'https://download.microsoft.com/SQL2025-SSEI-Dev.exe') {
    $lock.BootstrapUri=$bad
    Assert-Throws { Assert-CLSqlMediaLock $lock } '*Invalid Microsoft*'
}
$lock.BootstrapUri=$uri; $lock.IsoSha256='REPLACE'
Assert-Throws { Assert-CLSqlMediaLock $lock } '*Invalid SQL media hash*'
$lock.IsoSha256='b'*64; $lock.IsoBytes=11GB
Assert-Throws { Assert-CLSqlMediaLock $lock } '*Invalid SQL ISO size*'
$lock.IsoBytes=101MB
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-sql-test-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    Set-Content -LiteralPath (Join-Path $temp 'SQL2022-SSEI-Dev.exe') -Value 'synthetic-downloader'
    # Replace only the platform signature boundary for this behavioral test.
    function Assert-CLMicrosoftBinary { param([string]$Path) }
    function Start-Process { throw 'Unexpected process execution in offline test.' }
    function Invoke-WebRequest { throw 'Unexpected network call in offline test.' }
    Assert-Throws { Get-CLSqlDeveloperIso $temp $uri $lock } '*downloader checksum mismatch*'
    $lock.BootstrapSha256=(Get-FileHash (Join-Path $temp 'SQL2022-SSEI-Dev.exe')).Hash
    $isoPath=Join-Path $temp 'synthetic.iso'
    $stream=[IO.File]::Create($isoPath)
    try { $stream.SetLength(101MB) } finally { $stream.Dispose() }
    Assert-Throws { Get-CLSqlDeveloperIso $temp $uri $lock } '*Full SQL ISO checksum/size mismatch*'
    $lock.IsoSha256=(Get-FileHash $isoPath).Hash
    $result=Get-CLSqlDeveloperIso $temp $uri $lock
    if ($result.Sha256 -ne $lock.IsoSha256 -or $result.Bytes -ne 101MB) { throw 'Pinned cached ISO not reused.' }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process,Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
}
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Sql.psm1" -Force
function global:Invoke-CLGuest {
    param($Config,$VM,$Script,$OS)
    if ($Script -notmatch 'function Mount-CLSqlDeveloperIso' -or $Script -notmatch 'EditionID') { throw 'SQL guest payload missing media/edition guards.' }
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseInput($Script,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw 'SQL guest payload does not parse.' }
}
try { Invoke-CLWindowsScript @{Sql=@{}} $root 'Install-Sql.ps1' 'offline-vm' }
finally { Remove-Item Function:\Invoke-CLGuest }
Write-Output 'Offline SQL media lock, integrity, cached reuse and guest payload checks passed.'
