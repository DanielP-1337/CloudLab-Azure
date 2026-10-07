#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$ReceiptPath,[switch]$Interactive,[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
Write-Warning 'COST NOTICE: Downloads retained Azure blobs and restores a separate test database on the running SQL VM. Storage operations, transfer and VM runtime may incur charges.'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$ProjectRoot/Modules/CloudLab.Azure/HealthRecovery.psm1" -Force
$Config=Read-CLConfig $ConfigPath
Assert-CLHealthRecoveryProfile $Config
$full=(Resolve-Path -LiteralPath $ReceiptPath).Path
$local=[IO.Path]::GetFullPath((Join-Path $ProjectRoot '.local'))+[IO.Path]::DirectorySeparatorChar
if (-not $full.StartsWith($local,[StringComparison]::OrdinalIgnoreCase)) { throw 'Keep export receipts under .local.' }
$receipt=Get-Content -Raw -LiteralPath $full | ConvertFrom-Json
$entry=Get-CLHealthRestoreReceipt $receipt $Config
if (-not $PSCmdlet.ShouldProcess($Config.Sql.Name,'Restore a hash-verified export to a NEW restricted-user database, then run CHECKDB and reference-row and encrypted-value validation')) { return }
if (-not $EnableBillableResources) { throw 'Use -EnableBillableResources after reviewing the cost notice.' }
. "$PSScriptRoot/Initialize.ps1"
$Config.HealthRestore=$entry
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
    $state=Read-CLState $Config $ProjectRoot
    Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
    Assert-CLGroup $Config $state (Get-CLGroup $Config.SharedResourceGroup) -Retained
    # Can run with writers held in maintenance. Never resume them as a side effect.
    if ($state.Export) { $state.Export.Status='Invalidated' }
    Save-CLState $state (Get-CLStatePath $Config $ProjectRoot)
    $storage=Get-AzStorageAccount -ResourceGroupName $Config.SharedResourceGroup -Name $Config.Export.StorageAccount
    $scope="$($storage.Id)/blobServices/default/containers/$($Config.Export.Container)"
    $vm=Get-AzVM -ResourceGroupName $Config.ResourceGroup -Name $Config.Sql.Name
    $principal=[string]$vm.Identity.PrincipalId
    if (-not $principal) { throw 'SQL VM identity missing.' }
    $created=$false
    try {
        if (-not (Get-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName 'Storage Blob Data Reader' | Where-Object Scope -eq $scope)) {
            New-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName 'Storage Blob Data Reader' | Out-Null
            $created=$true
        }
        $script=Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Windows/Common.ps1" Windows
        $script+="`n"+(Get-Content -Raw "$ProjectRoot/Modules/CloudLab.Azure/HealthRecovery.psm1").Replace('Export-ModuleMember -Function *-CL*','')
        $script+="`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/HealthSqlBackup.ps1")
        $script+="`n"+(Get-Content -Raw "$ProjectRoot/Scripts/Windows/Restore-HealthSql.ps1")
        $marker='CL_RESTORE_SUCCESS_'+[guid]::NewGuid().ToString('N')
        $script="`$ErrorActionPreference='Stop'`n& {`n"+$script+"`n}`nWrite-Output '$marker'"
        $result=Invoke-AzVMRunCommand -ResourceGroupName $Config.ResourceGroup -VMName $Config.Sql.Name -CommandId RunPowerShellScript -ScriptString $script
        $messages=($result.Value | ForEach-Object Message) -join "`n"
        $restoreMatches=[regex]::Matches($messages,'CL_RESTORED_DATABASE=(CloudLabRestore_[a-f0-9]{32})')
        if ($messages -notmatch [regex]::Escape($marker) -or $restoreMatches.Count -ne 1) { throw 'Restore did not confirm success. Inspect protected guest logs; no raw output is printed.' }
        $report=@{Status='Passed';Database=$restoreMatches[0].Groups[1].Value;SourceBlob=$entry.Blob;Sha256=$entry.Sha256;Utc=[DateTime]::UtcNow.ToString('o')}
        $out=Join-Path $ProjectRoot ".local/results/$($state.DeploymentId)/restores"
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        $report | ConvertTo-Json | Set-Content (Join-Path $out ($report.Database+'.json')) -Encoding utf8
        Write-Output "Restore verified: $($report.Database). Existing application database was not replaced."
    } finally {
        if ($created) { Remove-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName 'Storage Blob Data Reader' | Out-Null }
    }
} finally { $lease.Dispose() }
