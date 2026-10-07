#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.local/config/lab.psd1'),
    [switch]$Login
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Write-Output 'Read-only Azure preflight. No resource creation, provider registration, role changes, or deployment.'
foreach ($module in 'Az.Accounts','Az.Resources','Az.Compute','Az.Storage','Az.KeyVault') {
    Import-Module $module -ErrorAction Stop
}
Import-Module "$projectRoot/Modules/CloudLab.Azure/Common.psm1" -Force
$config = Read-CLConfig -Path (Resolve-Path -LiteralPath $ConfigPath).Path
Disable-AzContextAutosave -Scope Process | Out-Null
if ($Login) {
    Connect-AzAccount -UseDeviceAuthentication -Tenant $config.TenantId `
        -Subscription $config.SubscriptionId -Scope Process | Out-Null
}
$context = Get-AzContext
if (-not $context -or $context.Subscription.Id -ne $config.SubscriptionId -or
    $context.Tenant.Id -ne $config.TenantId) {
    throw 'No matching Azure context. Run this script with -Login to use device authentication.'
}
'--- Local profile and Azure context ---'
[pscustomobject]@{
    ContextMatches = $true
    Location = $config.Location
    Environment = $config.Environment
    SqlExportMode = $config.Export.SqlMode
    QuiesceReviewed = $config.App.QuiesceReviewed
} | Format-List

'--- Existing subscription resources ---'
$resources = @(Get-AzResource)
"Resource count: $($resources.Count)"
$resources | Select-Object Name,ResourceType,ResourceGroupName | Format-Table -AutoSize

'--- Provider status ---'
$providerReport = foreach ($provider in @(
    'Microsoft.Compute','Microsoft.Network','Microsoft.Storage',
    'Microsoft.KeyVault','Microsoft.ManagedIdentity'
)) {
    Get-AzResourceProvider -ProviderNamespace $provider |
        Select-Object ProviderNamespace,RegistrationState -Unique
}
$providerReport | Format-Table -AutoSize
if (@($providerReport | Where-Object RegistrationState -ne 'Registered').Count) {
    Write-Warning 'One or more providers are not registered. This script does not register them.'
}

'--- Configured VM sizes and subscription restrictions ---'
$skus = @(Get-AzComputeResourceSku -Location $config.Location |
    Where-Object ResourceType -eq 'virtualMachines')
$vmPlan = @(
    foreach ($role in 'Keycloak','App','Sql') {
        $spec = $config[$role]
        $found = @($skus | Where-Object Name -eq $spec.Size)
        if ($found.Count -ne 1) { throw "SKU not found or ambiguous for ${role}: $($spec.Size)" }
        $sku = $found[0]
        $cpu = @($sku.Capabilities | Where-Object Name -eq 'vCPUs')
        if ($cpu.Count -ne 1 -or [int]$cpu[0].Value -lt 1) { throw "Missing/invalid vCPU count: $($spec.Size)" }
        [pscustomobject]@{
            Role = $role
            Size = $spec.Size
            Family = $sku.Family
            vCPUs = [int]$cpu[0].Value
            OsDisk = $spec.OsDiskType
            DataDisk = if ($role -ne 'Keycloak') {
                "$($spec.DataDiskType), $($spec.DiskGB) GiB"
            } else { '-' }
            Restrictions = ConvertTo-Json -InputObject @($sku.Restrictions) -Depth 8 -Compress
        }
    }
)
$vmPlan | Format-List

'--- Regional and VM-family quotas ---'
$usage = @(Get-AzVMUsage -Location $config.Location)
$quotaNames = @('cores','virtualMachines') + @($vmPlan.Family | Sort-Object -Unique)
# Collect loop output before piping it; a foreach statement is not a pipeline expression.
$quotaReport = foreach ($quotaName in $quotaNames) {
    $quota = @($usage | Where-Object { $_.Name.Value -eq $quotaName })
    if ($quota.Count -ne 1) { throw "Quota not found or ambiguous: $quotaName" }
    $needed = if ($quotaName -eq 'virtualMachines') {
        $vmPlan.Count
    } elseif ($quotaName -eq 'cores') {
        ($vmPlan | Measure-Object vCPUs -Sum).Sum
    } else {
        ($vmPlan | Where-Object Family -eq $quotaName | Measure-Object vCPUs -Sum).Sum
    }
    $free = $quota[0].Limit - $quota[0].CurrentValue
    [pscustomobject]@{
        Quota = $quotaName
        Used = $quota[0].CurrentValue
        Limit = $quota[0].Limit
        Available = $free
        Needed = $needed
        Fits = ($free -ge $needed)
    }
}
$quotaReport | Format-Table -AutoSize
if (@($quotaReport | Where-Object { -not $_.Fits }).Count) {
    Write-Warning 'Insufficient quota for the planned additional VMs.'
}

'--- Storage name availability ---'
Get-AzStorageAccountNameAvailability -Name $config.Export.StorageAccount |
    Format-List NameAvailable,Reason,Message
'--- Key Vault name availability ---'
Test-AzKeyVaultNameAvailability -Name $config.VaultName |
    Format-List NameAvailable,Reason,Message

'--- Direct user IAM assignments effective at subscription scope ---'
$signedInUser = Get-AzADUser -SignedIn
if (-not $signedInUser.Id) { throw 'Cannot resolve the signed-in user for the IAM check.' }
$scope = "/subscriptions/$($config.SubscriptionId)"
$roles = @(Get-AzRoleAssignment -ObjectId $signedInUser.Id -Scope $scope)
$roles | Select-Object RoleDefinitionName,Scope,Condition | Format-List
if ($roles.Count -eq 0) { Write-Warning 'No direct user assignments found at subscription scope or above; inspect group assignments below.' }

# ExpandPrincipalGroups belongs to a parameter set without Scope.
# Show each returned scope explicitly; a resource-group role is not subscription-wide.
'--- User and group assignments in the active subscription; inspect each scope ---'
$expandedRoles = @(Get-AzRoleAssignment -ObjectId $signedInUser.Id -ExpandPrincipalGroups)
$expandedRoles | Select-Object RoleDefinitionName,ObjectType,Scope,Condition |
    Sort-Object Scope,RoleDefinitionName -Unique | Format-List
if ($expandedRoles.Count -eq 0) { Write-Warning 'No expanded user/group assignments were returned.' }

Write-Output 'Read-only collection finished. Review restrictions, quotas, names and IAM before deployment.'
Write-Output 'This is not deployment approval: policies, deny assignments, live allocation capacity and guest installation are not fully validated.'
