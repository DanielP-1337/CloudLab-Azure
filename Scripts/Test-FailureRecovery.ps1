# Offline CloudLab lifecycle failure-recovery guards. No Az calls or Azure changes.
# EN-US. Run from Scripts/ in a checked-out CloudLab-Azure repository.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath (Join-Path $root 'Modules/CloudLab.Azure/Lifecycle.psm1'))) {
    throw 'Save this file as Scripts/Test-FailureRecovery.ps1 inside CloudLab-Azure.'
}
$files = @{
    Lifecycle = Join-Path $root 'Modules/CloudLab.Azure/Lifecycle.psm1'
    Deploy = Join-Path $root 'Runbooks/Deploy-Lab.ps1'
    Export = Join-Path $root 'Runbooks/Export-Lab.ps1'
    Destroy = Join-Path $root 'Runbooks/Destroy-Lab.ps1'
}
$source = @{}
foreach ($name in $files.Keys) { $source[$name] = Get-Content -LiteralPath $files[$name] -Raw }
$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Pass, [string]$Details) {
    $script:results.Add([pscustomobject]@{ Check=$Name; Passed=$Pass; Details=$Details })
}
function ContainsPattern([string]$File,[string]$Pattern) {
    [regex]::IsMatch($source[$File], $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
}
# Parse all checked sources before attempting dynamic simulations.
foreach ($name in $files.Keys) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($files[$name], [ref]$tokens, [ref]$errors)
    Check "$name parser" ($errors.Count -eq 0) 'PowerShell AST syntax'
}

# This exercises the actual inventory validator without importing Azure modules.
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($files.Lifecycle,[ref]$tokens,[ref]$errors)
$functions=@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
foreach ($functionName in 'Assert-CLDisposableInventory','Get-CLInventoryHash','Assert-CLGroup') {
    $def=@($functions | Where-Object Name -eq $functionName)
    if ($def.Count -ne 1) { throw "Cannot safely locate exactly one $functionName function." }
    . ([scriptblock]::Create($def[0].Extent.Text))
}
# Do not query Azure Monitoring; these tests contain no monitoring resources.
function Get-CLMonitoringNames { param($Config) @() }
$cfg=@{
    Prefix='lab'; VNetName='lab-vnet'; ProjectId=([guid]::NewGuid().ToString())
    Environment='sandbox'; SubscriptionId=([guid]::NewGuid().ToString())
    ResourceGroup='rg-lab-test'; SharedResourceGroup='rg-lab-retained'
    App=@{Name='lab-app'}; Sql=@{Name='lab-sql'}; Keycloak=@{Name='lab-auth'}
}
$state=@{DeploymentId=([guid]::NewGuid().ToString())}
function Item([string]$Name,[string]$Type) {
    @{Name=$Name;Type=$Type;Id="/subscriptions/$($cfg.SubscriptionId)/resourceGroups/$($cfg.ResourceGroup)/providers/$Type/$Name"}
}
$partial=@(
    (Item 'lab-vnet' 'Microsoft.Network/virtualNetworks'),
    (Item 'lab-AppSubnet-nsg' 'Microsoft.Network/networkSecurityGroups'),
    (Item 'lab-app-nic' 'Microsoft.Network/networkInterfaces'),
    (Item 'lab-app' 'Microsoft.Compute/virtualMachines'),
    (Item 'lab-app-os' 'Microsoft.Compute/disks'),
    (Item 'lab-app-data' 'Microsoft.Compute/disks')
)
$partialAllowed=$true
try { Assert-CLDisposableInventory $partial $cfg } catch { $partialAllowed=$false }
Check 'Partial App-only inventory' $partialAllowed 'Models failure before SQL/Keycloak VM deployment'

$unexpected=@($partial)+@((Item 'unknown-extra' 'Microsoft.Compute/disks'))
$unexpectedBlocked=$false
try { Assert-CLDisposableInventory $unexpected $cfg } catch { $unexpectedBlocked=$true }
Check 'Unexpected resource name rejected' $unexpectedBlocked 'Unknown resource cannot be silently deleted'

$unknownType=@($partial)+@((Item 'lab-sql' 'Microsoft.Storage/storageAccounts'))
$typeBlocked=$false
try { Assert-CLDisposableInventory $unknownType $cfg } catch { $typeBlocked=$true }
Check 'Unexpected resource type rejected' $typeBlocked 'Unknown resource type cannot be silently deleted'

$group=[pscustomobject]@{Tags=@{
    CloudLabProject=$cfg.ProjectId; CloudLabLifecycle='Ephemeral'
    CloudLabDeployment=$state.DeploymentId; CloudLabEnvironment=$cfg.Environment
}}
$groupAllowed=$true
try { Assert-CLGroup $cfg $state $group } catch { $groupAllowed=$false }
Check 'Ephemeral ownership accepted' $groupAllowed 'Matching project, lifecycle, environment, deployment'
$wrong=[pscustomobject]@{Tags=@{
    CloudLabProject=$cfg.ProjectId; CloudLabLifecycle='Retained'
    CloudLabDeployment=$state.DeploymentId; CloudLabEnvironment=$cfg.Environment
}}
$retainedBlocked=$false
try { Assert-CLGroup $cfg $state $wrong } catch { $retainedBlocked=$true }
Check 'Retained ownership rejected' $retainedBlocked 'Protects against deleting retained group as ephemeral'

$before=Get-CLInventoryHash $partial
$after=Get-CLInventoryHash $unexpected
Check 'Inventory drift changes hash' ($before -ne $after) 'Receipt must be invalidated by resource inventory changes'

# The real private profile can prohibit MetadataOnly despite the switch existing.
$privateConfigPath = Join-Path $root '.local/config/lab.psd1'
if (Test-Path -LiteralPath $privateConfigPath) {
    $private = Import-PowerShellDataFile -LiteralPath $privateConfigPath
    $native = $private.Export.ContainsKey('SqlMode') -and $private.Export.SqlMode -eq 'HealthNative'
    Check 'HealthNative profile detected' $native 'Expected native SQL recovery configuration'
    Check 'InfrastructureOnly recovery available' (
        (ContainsPattern 'Export' 'switch\]\s*\$InfrastructureOnly') -and
        (ContainsPattern 'Export' 'switch\]\s*\$AssertNoApplicationData') -and
        (ContainsPattern 'Export' 'Assert-CLInfrastructureOnly')
    ) 'Explicit infrastructure-only export path and operator attestation required'
} else {
    Check 'Private profile exists' $false 'Expected .local/config/lab.psd1 in checked-out repo'
}

# Static contract checks on the real runbooks (not runtime mocks).
Check 'Compute partial failure state' (ContainsPattern 'Deploy' "Status\s*=\s*'DeployFailed'") 'Failure state is persisted'
Check 'Compute ordered per-role' (ContainsPattern 'Deploy' 'foreach\s*\(\s*\$role\s+in\s+''App''\s*,\s*''Sql''\s*,\s*''Keycloak''\s*\)') 'Partial VM provisioning is possible'
Check 'Metadata export option' (ContainsPattern 'Export' 'switch\]\s*\$MetadataOnly') 'Metadata-only inventory export supported'
Check 'Export inventory guard' (ContainsPattern 'Export' 'Assert-CLDisposableInventory\s+\$inventory\s+\$Config') 'Unknown resources block export'
Check 'Export writes completion receipt' (ContainsPattern 'Export' '\$receipt\.Status\s*=\s*''Completed''') 'Status is set only after export work'
Check 'Export completion saved' (ContainsPattern 'Export' '\$state\.Export\s*=\s*\$receipt') 'Receipt persisted in lifecycle state'
Check 'Destroy requires receipt' (ContainsPattern 'Destroy' 'Assert-CLExport\s+\$Config\s+\$state\s+\$inventory') 'Normal destroy requires completed export'
Check 'Destroy validates inventory' (ContainsPattern 'Destroy' 'Assert-CLDisposableInventory\s+\$inventory\s+\$Config') 'Unknown resources block deletion'
Check 'Destroy exact RG match' (ContainsPattern 'Destroy' '-cne\s+\$Config\.ResourceGroup') 'Exact ephemeral resource group required'
Check 'Destroy excludes retained RG' (ContainsPattern 'Destroy' '-eq\s+\$Config\.SharedResourceGroup') 'Retained group excluded from delete target'
Check 'Destroy honors WhatIf' (ContainsPattern 'Destroy' '\$PSCmdlet\.ShouldProcess') 'SupportsShouldProcess also required'
Check 'Destroy supports ShouldProcess' (ContainsPattern 'Destroy' 'SupportsShouldProcess') 'Preview supported'
Check 'Destroy lock guard' (ContainsPattern 'Destroy' 'Get-AzResourceLock') 'Resource locks stop delete'
Check 'Destroy verifies removal' (ContainsPattern 'Destroy' 'if\s*\(Get-CLGroup\s+\$ExpectedResourceGroup\)') 'Deletion must be observed'
Check 'Destroy preserves retained group' (ContainsPattern 'Destroy' 'Assert-CLGroup\s+\$Config\s+\$state\s+\(Get-CLGroup\s+\$Config\.SharedResourceGroup\)\s+-Retained') 'Retained group validated post-deletion'

$results | Format-Table -AutoSize
$failures=@($results | Where-Object { -not $_.Passed })
if ($failures.Count) { throw "OFFLINE FAILURE RECOVERY: FAIL ($($failures.Count) checks). No Azure operations performed." }
Write-Host "OFFLINE FAILURE RECOVERY: PASS ($($results.Count) checks). No Azure operations performed." -ForegroundColor Green
Write-Warning 'Static contracts plus in-memory inventory/ownership simulation only; not a mocked end-to-end Azure export/deletion run.'
Write-Warning 'MetadataOnly is not VM/data backup. Export/storage permissions, guest failure recovery, and actual Azure deletion are not proven.'
