[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Interactive,[switch]$MetadataOnly,[switch]$EnableBillableResources)
Write-Warning 'COST NOTICE: Export pauses application writers and SQL Agent, runs SQL backup/restore validation, and uploads private blobs. VM runtime and storage operations may incur charges.'
if (-not $EnableBillableResources) { throw 'Review the cost notice and use -EnableBillableResources.' }
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
$state=Read-CLState $Config $ProjectRoot
Assert-CLNotInMaintenance $state
Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
Assert-CLGroup $Config $state (Get-CLGroup $Config.SharedResourceGroup) -Retained
if ($Config.Export.MaxArchiveMB -lt 1 -or $Config.Export.MaxArchiveMB -gt 512) { throw 'MaxArchiveMB must be 1..512.' }
$native=$Config.Export.ContainsKey('SqlMode') -and $Config.Export.SqlMode -eq 'HealthNative'
if ($native) {
    Import-Module "$ProjectRoot/Modules/CloudLab.Azure/HealthRecovery.psm1" -Force
    Assert-CLHealthRecoveryProfile $Config
    if ($MetadataOnly) { throw 'The native health recovery profile requires selected-file export, not MetadataOnly.' }
}
$inventory=Get-CLInventory $Config
Assert-CLDisposableInventory $inventory $Config
$Config.ExportRunId=$state.DeploymentId+'/'+[guid]::NewGuid().ToString('N')
$Config.BackupSetId=$Config.ExportRunId.Replace('/','-')
$out=Join-Path $ProjectRoot ".local/results/$($Config.ExportRunId)"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$receipt=@{ProjectId=$Config.ProjectId;SqlMode=$(if ($native) {'HealthNative'} else {'Custom'});Status='InProgress';Utc=[DateTime]::UtcNow.ToString('o');InventoryHash=(Get-CLInventoryHash $inventory);StorageAccount=$Config.Export.StorageAccount;Container=$Config.Export.Container;Mode=$(if($MetadataOnly){'MetadataOnly'}else{'SelectedFiles'});Blobs=@();MaintenanceId=$Config.BackupSetId}
$state.Export=$receipt; Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
$appStopped=$false; $sqlStopped=$false
try {
    $inventory | ConvertTo-Json -Depth 15 | Set-Content "$out/inventory.json"
    $receipt.Blobs += Write-CLArtifact $Config "$out/inventory.json" "$($Config.ExportRunId)/inventory.json"
    $testFile=Join-Path $ProjectRoot ".local/results/$($state.DeploymentId)/tests.json"
    if (Test-Path $testFile) { $receipt.Blobs += Write-CLArtifact $Config $testFile "$($Config.ExportRunId)/tests.json" }
    $monitorEvidence=Export-CLMonitoringEvidence $Config $state $out
    if ($monitorEvidence) { $receipt.Blobs += Write-CLArtifact $Config $monitorEvidence "$($Config.ExportRunId)/monitoring-summary.json" }
    if (-not $MetadataOnly) {
        if (-not $Config.App.QuiesceReviewed) { throw 'Review all writers and set App.QuiesceReviewed before selected-file export.' }
        $state.Maintenance=@{Id=$Config.BackupSetId}; Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
        # Save flags before calls: partial stop failures must still attempt resume.
        $appStopped=$true; Invoke-CLWindowsScript $Config $ProjectRoot 'Quiesce-Application.ps1' $Config.App.Name
        $sqlStopped=$true; Invoke-CLWindowsScript $Config $ProjectRoot 'Quiesce-Sql.ps1' $Config.Sql.Name
        $storage=Get-AzStorageAccount -Name $Config.Export.StorageAccount -ResourceGroupName $Config.SharedResourceGroup
        $scope="$($storage.Id)/blobServices/default/containers/$($Config.Export.Container)"
        foreach ($role in 'App','Sql','Keycloak') {
            $vm=Get-AzVM -Name $Config[$role].Name -ResourceGroupName $Config.ResourceGroup
            $principal=[string]$vm.Identity.PrincipalId
            if (-not $principal) { throw 'Guest has no managed identity.' }
            $state.Principals=@($state.Principals+@($principal) | Sort-Object -Unique)
            Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
            $createdRole=$false
            if (-not (Get-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName 'Storage Blob Data Contributor' | Where-Object Scope -eq $scope)) {
                New-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName 'Storage Blob Data Contributor' | Out-Null
                $createdRole=$true
            }
            try {
                if ($role -eq 'Keycloak') {
                    $body=Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Linux/Export-Files.sh" Linux
                    Invoke-CLGuest $Config $vm.Name $body Linux
                    $blobName="$($Config.ExportRunId)/Keycloak.tar.gz"
                } else {
                    $body=Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Windows/Common.ps1" Windows
                    if ($role -eq 'Sql' -and $native) { $body+="`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/HealthSqlBackup.ps1") }
                    $body+="`n`$ExportRole='$role'`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/Export-Files.ps1")
                    Invoke-CLGuest $Config $vm.Name $body Windows
                    $blobName="$($Config.ExportRunId)/$role.zip"
                }
                $blob=Get-AzStorageBlob -Container $Config.Export.Container -Blob $blobName -Context (Get-CLStorageContext $Config)
                $properties=$blob.BlobClient.GetProperties().Value
                if (-not $properties.Metadata.ContainsKey('sha256') -or $properties.ContentLength -le 0) { throw 'Guest export has no content/hash.' }
                $receipt.Blobs += @{Blob=$blobName;Length=[long]$properties.ContentLength;ETag=[string]$properties.ETag;Sha256=$properties.Metadata['sha256']}
            } finally {
                if ($createdRole) { Remove-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName 'Storage Blob Data Contributor' | Out-Null }
            }
        }
    }
    $receipt.Status='Completed'
    $receipt | ConvertTo-Json -Depth 20 | Set-Content "$out/export-receipt.json"
    $receipt.Blobs += Write-CLArtifact $Config "$out/export-receipt.json" "$($Config.ExportRunId)/export-receipt.json"
    Write-Output "Export completed ($($receipt.Mode)). Selected files remain private in retained storage."
    if (-not $MetadataOnly) { Write-Output 'Application writers and SQL Agent remain stopped until Destroy or Resume-Lab.' }
} catch {
    $receipt.Status='Failed'
    try { if ($sqlStopped) { Invoke-CLWindowsScript $Config $ProjectRoot 'Resume-Sql.ps1' $Config.Sql.Name } }
    finally { if ($appStopped) { Invoke-CLWindowsScript $Config $ProjectRoot 'Resume-Application.ps1' $Config.App.Name } }
    $state.Maintenance=$null
    throw
} finally {
    $state.Export=$receipt
    Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
}

} finally { $lease.Dispose() }
