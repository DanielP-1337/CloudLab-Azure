[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Interactive,[Parameter(Mandatory)][string]$ExpectedResourceGroup)
. "$PSScriptRoot/Initialize.ps1"
$lease=Enter-CLLifecycleLock $Config $ProjectRoot
try {
$state=Read-CLState $Config $ProjectRoot
$statePath=Get-CLStatePath $Config $ProjectRoot
if ($ExpectedResourceGroup -cne $Config.ResourceGroup -or $ExpectedResourceGroup -eq $Config.SharedResourceGroup) { throw 'Exact workload resource-group name required.' }
$group=Get-CLGroup $Config.ResourceGroup
if (-not $group) {
    if ($state.Status -notin @('Deleting','DeleteFailed','Destroyed')) { throw 'Group unexpectedly absent; investigate before accepting cleanup.' }
    if ($state.Status -eq 'Destroyed') { Write-Output 'Already destroyed.'; return }
} else {
    Assert-CLGroup $Config $state $group
    $inventory=Get-CLInventory $Config
    Assert-CLDisposableInventory $inventory $Config
    if ($state.Status -notin @('Deleting','DeleteFailed')) { Assert-CLExport $Config $state $inventory }
    elseif (-not $state.ContainsKey('DeletionApprovedInventory')) { throw 'Missing original deletion inventory.' }
    else {
        foreach ($item in $inventory) { if ($item.Id -notin $state.DeletionApprovedInventory) { throw 'New resource found during delete retry.' } }
    }
    # Never remove locks or backup protection automatically.
    $locks=@(Get-AzResourceLock -ResourceGroupName $Config.ResourceGroup)
    if ($locks.Count) { throw 'Resource locks exist; deletion blocked.' }
}
if (-not $PSCmdlet.ShouldProcess($ExpectedResourceGroup,'Delete the entire disposable group and its test data')) { return }
if ($group) {
    Assert-CLGroup $Config $state (Get-CLGroup $Config.ResourceGroup)
    $latest=Get-CLInventory $Config
    if ((Get-CLInventoryHash $latest) -ne (Get-CLInventoryHash $inventory)) { throw 'Inventory changed while awaiting confirmation.' }
    if ($state.Status -notin @('Deleting','DeleteFailed')) { $state.DeletionApprovedInventory=@($inventory.Id) }
    $state.Status='Deleting'; Save-CLState $state $statePath
    try {
        Remove-CLExternalRoles $Config $state
        Remove-AzResourceGroup -Name $ExpectedResourceGroup -Force -ErrorAction Stop | Out-Null
    } catch { $state.Status='DeleteFailed'; Save-CLState $state $statePath; throw }
}
# A failed API/list call is NOT interpreted as successful deletion.
if (Get-CLGroup $ExpectedResourceGroup) { throw 'Resource group still exists. Cleanup is incomplete.' }
$remaining=@(Get-AzResource | Where-Object { $_.ResourceGroupName -eq $ExpectedResourceGroup })
if ($remaining.Count) { throw 'Resources remain in deleted scope.' }
Assert-CLGroup $Config $state (Get-CLGroup $Config.SharedResourceGroup) -Retained
$state.Status='Destroyed'; $state.DestroyedUtc=[DateTime]::UtcNow.ToString('o')
Save-CLState $state $statePath
Write-Output 'Disposable group deletion verified. Retained storage/vault still exist and can incur charges.'

} finally { $lease.Dispose() }
