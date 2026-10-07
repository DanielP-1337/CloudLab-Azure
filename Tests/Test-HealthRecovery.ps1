# Offline only: no Azure calls, certificates, SQL engine or installations.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root/Modules/CloudLab.Azure/HealthRecovery.psm1" -Force
function Assert-Throws([scriptblock]$Block) {
    $failed=$false;try { & $Block | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'Expected rejection.' }
}
$c=@{ProjectId='test-project';Environment='sandbox';HealthSql=@{Enabled=$true}
    App=@{Provider='InfrastructureHealth';WriterServices=@();QuiesceReviewed=$false}
    Sql=@{Instance='MSSQLSERVER';Databases=@('CloudLabHealth')}
    Export=@{StorageAccount='teststorage';Container='exports';SqlPreparePath='';SqlPrepareSha256=''}}
Assert-CLHealthRecoveryProfile $c
$c.App.WriterServices=@('unexpected');Assert-Throws { Assert-CLHealthRecoveryProfile $c };$c.App.WriterServices=@()
$c.Environment='production';Assert-Throws { Assert-CLHealthRecoveryProfile $c };$c.Environment='sandbox'
$blob=([guid]::NewGuid().ToString())+'/'+[guid]::NewGuid().ToString('N')+'/Sql.zip'
$receipt=@{ProjectId=$c.ProjectId;Status='Completed';Mode='SelectedFiles';SqlMode='HealthNative';StorageAccount='teststorage';Container='exports';Blobs=@(@{Blob=$blob;Sha256=('a'*64);Length=100})}
Get-CLHealthRestoreReceipt $receipt $c | Out-Null
$receipt.ProjectId='other';Assert-Throws { Get-CLHealthRestoreReceipt $receipt $c };$receipt.ProjectId=$c.ProjectId
$receipt.Mode='MetadataOnly';Assert-Throws { Get-CLHealthRestoreReceipt $receipt $c };$receipt.Mode='SelectedFiles'
$receipt.Blobs+=@($receipt.Blobs[0]);Assert-Throws { Get-CLHealthRestoreReceipt $receipt $c };$receipt.Blobs=@($receipt.Blobs[0])
$receipt.Blobs[0].Blob='../Sql.zip';Assert-Throws { Get-CLHealthRestoreReceipt $receipt $c }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-recovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
function New-TestZip([string]$Path,[string[]]$Entries) {
    $z=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try { foreach ($name in $Entries) { $entry=$z.CreateEntry($name);$writer=[IO.StreamWriter]::new($entry.Open());try {$writer.Write('synthetic')} finally {$writer.Dispose()} } }
    finally { $z.Dispose() }
}
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-TestZip "$temp/good.zip" @('0/CloudLabHealth.bak','0/backup-manifest.json','selection.json')
    Expand-CLHealthArchive "$temp/good.zip" "$temp/good"
    if ((Get-Content -Raw "$temp/good/0/CloudLabHealth.bak") -ne 'synthetic') { throw 'Archive extraction failed.' }
    Assert-Throws { Expand-CLHealthArchive "$temp/good.zip" "$temp/good" }
    New-TestZip "$temp/traversal.zip" @('0/CloudLabHealth.bak','0/backup-manifest.json','../outside')
    Assert-Throws { Expand-CLHealthArchive "$temp/traversal.zip" "$temp/bad1" }
    if (Test-Path "$temp/bad1") { throw 'Rejected archive created output.' }
    New-TestZip "$temp/duplicate.zip" @('0/CloudLabHealth.bak','0/backup-manifest.json','0/CloudLabHealth.bak')
    Assert-Throws { Expand-CLHealthArchive "$temp/duplicate.zip" "$temp/bad2" }
    New-Item -ItemType Directory -Path "$temp/Scripts","$temp/Modules/CloudLab.Azure","$temp/.local/config" -Force | Out-Null
    Copy-Item "$root/Scripts/Initialize-HealthRecovery.ps1" "$temp/Scripts/"
    Copy-Item "$root/Modules/CloudLab.Azure/HealthRecovery.psm1" "$temp/Modules/CloudLab.Azure/"
    @'
@{
 ProjectId='test-project';Environment='sandbox';HealthSql=@{Enabled=$true}
 App=@{Provider='InfrastructureHealth';WriterServices=@();QuiesceReviewed=$false}
 Sql=@{Instance='MSSQLSERVER';Databases=@('CloudLabHealth')}
 Export=@{StorageAccount='keep-me';SqlPreparePath='';SqlPrepareSha256=''}
}
'@ | Set-Content "$temp/.local/config/lab.psd1"
    $before=Get-Content -Raw "$temp/.local/config/lab.psd1"
    & "$temp/Scripts/Initialize-HealthRecovery.ps1" -WhatIf
    if ((Get-Content -Raw "$temp/.local/config/lab.psd1") -cne $before) { throw 'WhatIf changed config.' }
    & "$temp/Scripts/Initialize-HealthRecovery.ps1"
    $after=Get-Content -Raw "$temp/.local/config/lab.psd1"
    $updated=Import-PowerShellDataFile "$temp/.local/config/lab.psd1"
    if (-not $updated.App.QuiesceReviewed -or $updated.Export.SqlMode -ne 'HealthNative' -or $updated.Export.StorageAccount -ne 'keep-me') { throw 'Config migration failed.' }
    & "$temp/Scripts/Initialize-HealthRecovery.ps1"
    if ((Get-Content -Raw "$temp/.local/config/lab.psd1") -cne $after) { throw 'Config migration not idempotent.' }
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
foreach ($file in 'Export-Files.ps1','Restore-HealthSql.ps1') {
    $payload=Get-CLGuestPayload $c "$root/Scripts/Windows/Common.ps1" Windows
    $payload+="`n"+(Get-Content -Raw "$root/Modules/CloudLab.Azure/HealthRecovery.psm1").Replace('Export-ModuleMember -Function *-CL*','')
    $payload+="`n"+(Get-Content -Raw "$root/Scripts/Windows/HealthSqlBackup.ps1")
    $payload+="`n"+(Get-Content -Raw "$root/Scripts/Windows/$file")
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseInput($payload,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw 'Composed recovery payload does not parse.' }
}
Write-Output 'Offline recovery profile, receipt, archive, config and guest-payload checks passed.'
