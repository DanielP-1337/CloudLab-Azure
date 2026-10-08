# Offline-only Compute safety preflight. No Az module loading, Azure calls or writes.
# Run with PowerShell 7+ from any working directory.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$AllowLatestImages
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (-not (Test-Path -LiteralPath (Join-Path $root 'Modules/CloudLab.Azure/Compute.psm1'))) {
    throw 'Run from the CloudLab-Azure repository root.'
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root '.local/config/lab.psd1'
}
$fullConfig = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $root '.local/config')) + [IO.Path]::DirectorySeparatorChar
if (-not $fullConfig.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use only a private .local/config/*.psd1 configuration.'
}
$c = Import-PowerShellDataFile -LiteralPath $fullConfig
$computeText = Get-Content -Raw -LiteralPath (Join-Path $root 'Modules/CloudLab.Azure/Compute.psm1')
$commonText = Get-Content -Raw -LiteralPath (Join-Path $root 'Modules/CloudLab.Azure/Common.psm1')
$deployText = Get-Content -Raw -LiteralPath (Join-Path $root 'Runbooks/Deploy-Lab.ps1')
$checks = [System.Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Pass,[string]$Details) {
    $script:checks.Add([pscustomobject]@{ Check=$Name; Passed=$Pass; Details=$Details })
}
function SourceHas([string]$Text,[string]$Pattern) { return [regex]::IsMatch($Text,$Pattern) }

Check 'Environment is sandbox' ($c.Environment -eq 'sandbox') 'Expected disposable sandbox'
Check 'Region' ($c.Location -eq 'germanywestcentral') 'Expected germanywestcentral'
Check 'Image source wired to config' (SourceHas $computeText 'Set-AzVMSourceImage\s+-PublisherName\s+\$spec\.Publisher\s+-Offer\s+\$spec\.Offer\s+-Skus\s+\$spec\.Sku\s+-Version\s+\$spec\.ImageVersion') 'VM image fields must derive from per-role config'
Check 'Trusted Launch selected' (SourceHas $computeText 'New-AzVMConfig[^\r\n]*-SecurityType\s+TrustedLaunch') 'SecurityType TrustedLaunch'
Check 'Secure Boot enabled' (SourceHas $computeText '-EnableSecureBoot\s+\$true') 'Secure Boot enabled'
Check 'vTPM enabled' (SourceHas $computeText '-EnableVtpm\s+\$true') 'vTPM enabled'
Check 'System-assigned identity' (SourceHas $computeText '-IdentityType\s+SystemAssigned') 'VM system identity'
Check 'No public IP attached in VM creation' (-not (SourceHas $computeText 'New-AzPublicIpAddress|Add-AzVMNetworkInterface[^\r\n]*PublicIp')) 'Static source inspection only'
Check 'Windows VM agent provisioned' (SourceHas $computeText 'Set-AzVMOperatingSystem[^\r\n]*-Windows[^\r\n]*-ProvisionVMAgent') 'Windows agent configured'
Check 'Linux SSH public-key auth' ((SourceHas $computeText '-DisablePasswordAuthentication') -and (SourceHas $computeText 'Add-AzVMSshPublicKey')) 'Linux image agent availability not locally provable'
Check 'Run Command ID Windows' (SourceHas $commonText "'RunPowerShellScript'") 'Invoke-AzVMRunCommand Windows'
Check 'Run Command ID Linux' (SourceHas $commonText "'RunShellScript'") 'Invoke-AzVMRunCommand Linux'
Check 'Run Command used' (SourceHas $commonText 'Invoke-AzVMRunCommand\s+-ResourceGroupName') 'Requires functioning guest agent and connectivity'
Check 'Run Command success marker required' ((SourceHas $commonText 'CL_SUCCESS_') -and (SourceHas $commonText 'Guest operation failed')) 'Guest execution is checked, not just HTTP completion'
Check 'Compute billable gate' (SourceHas $deployText "-notin @\('Bootstrap','Network'\).*EnableBillableResources") 'Compute requires explicit billing switch'
Check 'Compute stage separated' (SourceHas $deployText "Compute\s*\{") 'Compute can run independently of Egress'

$expect = @{
  App = @{ Size='Standard_D2as_v6'; OsDiskType='StandardSSD_LRS'; DataDiskType='Standard_LRS'; DiskGB=32; Publisher='MicrosoftWindowsServer'; Offer='WindowsServer'; Sku='2025-datacenter-g2' }
  Sql = @{ Size='Standard_D2as_v6'; OsDiskType='StandardSSD_LRS'; DataDiskType='StandardSSD_LRS'; DiskGB=32; Publisher='MicrosoftWindowsServer'; Offer='WindowsServer'; Sku='2025-datacenter-g2' }
  Keycloak = @{ Size='Standard_D2as_v6'; OsDiskType='StandardSSD_LRS'; Publisher='Canonical'; Offer='ubuntu-24_04-lts'; Sku='server' }
}
foreach ($role in 'App','Sql','Keycloak') {
    $spec = $c[$role]
    Check "$role section present" ($null -ne $spec) 'Private lab configuration'
    if ($null -eq $spec) { continue }
    foreach ($key in $expect[$role].Keys) {
        Check "$role.$key" ([string]$spec[$key] -ceq [string]$expect[$role][$key]) "Expected $($expect[$role][$key])"
    }
    $version = [string]$spec.ImageVersion
    $isPinned = ($version -ne 'latest' -and $version -match '^\d+(?:\.\d+){2,4}$')
    Check "$role image version" ($isPinned -or $AllowLatestImages.IsPresent) $(if ($isPinned) {'Pinned numeric version'} else {'Not pinned; actual image availability must be confirmed separately in Azure'})
}
Check 'SSH public key format' ([string]$c.SshPublicKey -match '^ssh-(rsa|ed25519)\s+\S+') 'Does not print the public key'
Check 'Windows password secret reference' (-not [string]::IsNullOrWhiteSpace([string]$c.WindowsPasswordSecret)) 'Does not access or print the secret'
$autogrowPath = Join-Path $root '.local/config/autogrow.psd1'
Check 'Auto-grow config present' (Test-Path -LiteralPath $autogrowPath) 'Required for smoke test'
if (Test-Path -LiteralPath $autogrowPath) {
    $auto = Import-PowerShellDataFile -LiteralPath $autogrowPath
    Check 'Auto-grow disabled' ($auto.Enabled -eq $false) 'No unexpected disk expansion'
}
$checks | Format-Table -AutoSize -Wrap
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count) { throw "OFFLINE COMPUTE SAFETY: FAIL ($($failed.Count) checks). No Azure operations performed." }
Write-Host 'OFFLINE COMPUTE SAFETY: PASS. No Azure operations performed.' -ForegroundColor Green
Write-Warning 'Static checks do NOT verify Azure-side Trusted Launch support, image/VM SKU compatibility, VM Agent readiness, quota/capacity, or outbound service reachability.'
