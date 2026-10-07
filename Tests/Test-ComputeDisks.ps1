# Offline disk selection, drift, and local migration checks. No Azure access.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
Import-Module "$root/Modules/CloudLab.Azure/Compute.psm1" -Force
function Assert-Throws([scriptblock]$Block) {
    $threw = $false
    try { & $Block | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected a guard failure.' }
}
$c = Import-PowerShellDataFile "$root/Config/lab.example.psd1"
$os = [pscustomobject]@{ Sku=@{Name='StandardSSD_LRS'}; DiskSizeGB=128 }
$hdd = [pscustomobject]@{ Sku=@{Name='Standard_LRS'}; DiskSizeGB=512 }
$ssd = [pscustomobject]@{ Sku=@{Name='StandardSSD_LRS'}; DiskSizeGB=32 }
Assert-CLDiskProfile $c App $os $hdd
Assert-CLDiskProfile $c Sql $os $ssd
Assert-CLDiskProfile $c Keycloak $os $null
Assert-Throws { Assert-CLDiskProfile $c App $os $ssd }
Assert-Throws { Assert-CLDiskProfile $c Sql $os $null }
$hdd.DiskSizeGB=64
Assert-Throws { Assert-CLDiskProfile $c App $os $hdd }
$c.App.DataDiskType='Premium_LRS'
$hdd.DiskSizeGB=512; $hdd.Sku.Name='Premium_LRS'
Assert-CLDiskProfile $c App $os $hdd
$c.App.DataDiskType='UltraSSD_LRS'
Assert-Throws { Get-CLDiskSettings $c App }
$c.App.Remove('OsDiskType')
Assert-Throws { Get-CLDiskSettings $c App }

# Exercise the real local helper against a legacy-shaped configuration.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-test-'+[guid]::NewGuid().ToString('N'))
try {
    foreach ($dir in 'Scripts','Modules/CloudLab.Azure','.local/config','.local/state') {
        New-Item -ItemType Directory -Path (Join-Path $temp $dir) -Force | Out-Null
    }
    Copy-Item "$root/Scripts/Set-SmokeTestConfig.ps1" "$temp/Scripts/"
    Copy-Item "$root/Modules/CloudLab.Azure/Common.psm1" "$temp/Modules/CloudLab.Azure/"
    $text = Get-Content -Raw "$root/Config/lab.example.psd1"
    foreach ($name in 'subscription','tenant','local-project') {
        $text = $text.Replace("REPLACE-$name-guid",[guid]::NewGuid().ToString())
    }
    $text = $text.Replace('REPLACE-test-resource-group','rg-lab-test').Replace('REPLACE-retained-resource-group','rg-lab-retained')
    $text = $text.Replace('REPLACE-unique-vault-name','kv-lab-test').Replace('REPLACE-unique-storage-account','stlabtest')
    $text = [regex]::Replace($text, "OsDiskType = '[^']+';?", '')
    $text = [regex]::Replace($text, "DataDiskType = '[^']+';?", '')
    $text = $text.Replace("Location = 'germanywestcentral'", "Location = 'australiaeast'")
    $text = $text.Replace("Size = 'Standard_D2as_v6'", "Size = 'Standard_D4s_v5'")
    $text = $text.Replace('DiskGB = 32','DiskGB = 128').Replace('MaxMemoryMB = 4096','MaxMemoryMB = 8192')
    $path = "$temp/.local/config/lab.psd1"
    Set-Content $path $text
    $before = Import-PowerShellDataFile $path
    & "$temp/Scripts/Set-SmokeTestConfig.ps1" -WhatIf
    if ((Get-Content -Raw $path).TrimEnd() -ne $text.TrimEnd()) { throw 'WhatIf modified the config.' }
    & "$temp/Scripts/Set-SmokeTestConfig.ps1" -Confirm:$false
    $after = Import-PowerShellDataFile $path
    if ($after.Location -ne 'germanywestcentral' -or $after.App.DataDiskType -ne 'Standard_LRS' -or $after.App.DiskGB -ne 512 -or $after.Sql.MaxMemoryMB -ne 4096) { throw 'Migration failed.' }
    foreach ($role in 'Keycloak','App','Sql') {
        if ($after[$role].Size -ne 'Standard_D2as_v6') { throw 'VM size migration failed.' }
    }
    foreach ($key in 'SubscriptionId','TenantId','ProjectId','AppHost','ResourceGroup','SharedResourceGroup') {
        if ($before[$key] -ne $after[$key]) { throw 'Unrelated config value changed.' }
    }
    $bytes = [IO.File]::ReadAllText($path)
    & "$temp/Scripts/Set-SmokeTestConfig.ps1" -Confirm:$false
    if ([IO.File]::ReadAllText($path) -ne $bytes) { throw 'Migration is not idempotent.' }
    Set-Content "$temp/.local/state/sandbox.json" '{}'
    Assert-Throws { & "$temp/Scripts/Set-SmokeTestConfig.ps1" -Confirm:$false }
} finally {
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
}
Write-Output 'Offline disk and local config migration tests passed.'
