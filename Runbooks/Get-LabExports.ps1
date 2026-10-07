[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Interactive)
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
$state=Read-CLState $Config $ProjectRoot
if (-not $state.Export -or $state.Export.Status -ne 'Completed') { throw 'No complete export receipt.' }
$out=Join-Path $ProjectRoot ".local/results/$($state.DeploymentId)/downloads"
New-Item -ItemType Directory -Path $out -Force | Out-Null
foreach ($receipt in $state.Export.Blobs) {
    $file=Join-Path $out ([IO.Path]::GetFileName($receipt.Blob))
    Get-AzStorageBlobContent -Container $Config.Export.Container -Blob $receipt.Blob -Context (Get-CLStorageContext $Config) -Destination $file -Force | Out-Null
    if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $receipt.Sha256) { throw 'Downloaded artifact checksum mismatch.' }
}
Write-Output "Exports downloaded and checksums verified: $out"

} finally { $lease.Dispose() }
