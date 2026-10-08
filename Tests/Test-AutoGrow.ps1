[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$root/Scripts/Windows/AutoGrow.Core.ps1"
function Assert-True($value,$message) { if (-not $value) { throw $message } }
function Assert-Throws([scriptblock]$body) { $failed=$false; try { & $body } catch { $failed=$true }; if (-not $failed) { throw 'Expected rejection.' } }
$s=Import-PowerShellDataFile "$root/Config/autogrow.example.psd1"
Assert-CLAutoGrowSettings $s
Assert-True (-not $s.Enabled) 'Must default disabled.'
$s.Enabled=$true
Assert-Throws { Assert-CLAutoGrowSettings $s }
$s.DiskBindingReviewed=$true; $s.GuestDiskUniqueId='offline-test-disk'
Assert-CLAutoGrowSettings $s
Assert-True ((Get-CLAutoGrowTarget $s 512) -eq 640) 'Percent calculation.'
Assert-True ((Get-CLAutoGrowTarget $s 4000) -eq 4096) 'Cap.'
Assert-True ((Get-CLAutoGrowTarget $s 4096) -eq 4096) 'At cap.'
$s.GrowthMode='FixedMiB'
Assert-True ((Get-CLAutoGrowTarget $s 512) -eq 576) 'Fixed increment.'
$s.GrowthMiB=1
Assert-True ((Get-CLAutoGrowTarget $s 512) -eq 513) 'Whole GiB rounding.'
$s.GrowthMiB=1025
Assert-True ((Get-CLAutoGrowTarget $s 512) -eq 514) 'Nonwhole rounding.'
foreach ($key in 'GrowthPercent','GrowthMiB','MaxSizeGiB','CheckMinutes','CooldownMinutes') {
    $old=$s[$key]; $s[$key]=0; Assert-Throws { Assert-CLAutoGrowSettings $s }; $s[$key]=$old
}
$s.MaxSizeGiB=4097; Assert-Throws { Assert-CLAutoGrowSettings $s }; $s.MaxSizeGiB=4096
$s.GrowthMode='Invalid'; Assert-Throws { Assert-CLAutoGrowSettings $s }; $s.GrowthMode='FixedMiB'
Assert-True (Test-CLAutoGrowPressure $s (512GB) (100GB)) 'Percent threshold.'
Assert-True (Test-CLAutoGrowPressure $s (100GB) (40GB)) 'Absolute threshold.'
Assert-True (-not (Test-CLAutoGrowPressure $s (512GB) (200GB))) 'No pressure.'
Assert-Throws { Test-CLAutoGrowPressure $s 0 0 }
# Behavior test disk binding: no DiskNumber guessing, reject wrong/boot/MBR layouts.
$s.DriveLetter='F'
$script:disk=[pscustomobject]@{Number=2;UniqueId='offline-test-disk';IsBoot=$false;IsSystem=$false;IsOffline=$false;IsReadOnly=$false;PartitionStyle='GPT';BusType='NVMe'}
function Get-Disk { param($Number) $script:disk }
function Get-Partition { param($DriveLetter,$DiskNumber) [pscustomobject]@{DiskNumber=2;PartitionNumber=2;Type='Basic'} }
function Get-Volume { param($DriveLetter) [pscustomobject]@{FileSystem='NTFS';HealthStatus='Healthy'} }
Get-CLAutoGrowVolume $s | Out-Null
$script:disk.IsBoot=$true; Assert-Throws { Get-CLAutoGrowVolume $s }; $script:disk.IsBoot=$false
$script:disk.UniqueId='wrong'; Assert-Throws { Get-CLAutoGrowVolume $s }; $script:disk.UniqueId='offline-test-disk'
$script:disk.PartitionStyle='MBR'; Assert-Throws { Get-CLAutoGrowVolume $s }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-grow-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path "$temp/Scripts","$temp/Config","$temp/.local/config" -Force | Out-Null
    Copy-Item "$root/Scripts/Initialize-AutoGrow.ps1" "$temp/Scripts"
    Copy-Item "$root/Config/autogrow.example.psd1" "$temp/Config"
    & "$temp/Scripts/Initialize-AutoGrow.ps1" -WhatIf
    Assert-True (-not (Test-Path "$temp/.local/config/autogrow.psd1")) 'WhatIf wrote a file.'
    & "$temp/Scripts/Initialize-AutoGrow.ps1"
    $hash=(Get-FileHash "$temp/.local/config/autogrow.psd1").Hash
    & "$temp/Scripts/Initialize-AutoGrow.ps1"
    Assert-True ((Get-FileHash "$temp/.local/config/autogrow.psd1").Hash -eq $hash) 'Existing settings overwritten.'
} finally { Remove-Item -Recurse -Force $temp }
Write-Output 'Offline auto-grow limits, step calculations, thresholds, disk binding and opt-in checks passed.'
# Journal timestamp types must retain the same instant in both host cultures.
$oldCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    $instant=[DateTimeOffset]::UtcNow
    foreach ($culture in 'de-DE','en-US') {
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach ($value in @($instant,$instant.UtcDateTime,$instant.LocalDateTime,$instant.ToString('o'),$instant.ToOffset([TimeSpan]::FromHours(2)).ToString('o'))) {
            Assert-True ((ConvertTo-CLAutoGrowUtc $value) -eq $instant) 'Journal timestamp changed instant.'
        }
        $roundtrip=(@{LastAttemptUtc=$instant.ToString('o')} | ConvertTo-Json | ConvertFrom-Json).LastAttemptUtc
        Assert-True ((ConvertTo-CLAutoGrowUtc $roundtrip) -eq $instant) 'JSON journal timestamp changed instant.'
    }
    Assert-Throws { ConvertTo-CLAutoGrowUtc '08.10.2026 12:00:00' }
    Assert-Throws { ConvertTo-CLAutoGrowUtc ([DateTime]::SpecifyKind($instant.UtcDateTime,[DateTimeKind]::Unspecified)) }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture=$oldCulture }

# Execute the actual guest worker against mocked Azure and Windows storage APIs.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-worker-'+[guid]::NewGuid().ToString('N'))
$oldProgramData=$env:ProgramData
$oldWorkerCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $env:ProgramData=$temp
    $base=Join-Path $temp 'CloudLab/AutoGrow'
    New-Item -ItemType Directory $base -Force | Out-Null
    Copy-Item "$root/Scripts/Windows/AutoGrow.Core.ps1" $base
    $s=Import-PowerShellDataFile "$root/Config/autogrow.example.psd1"
    $s.Enabled=$true; $s.DiskBindingReviewed=$true; $s.GuestDiskUniqueId='test-disk'; $s.DriveLetter='F'
    $s.DiskId='/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/disks/app-data'
    $s.AzureDiskUniqueId='azure-disk'; $s.VmId='/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/app'
    $s.DiskType='Standard_LRS'; $s.InitialGiB=512
    $s | ConvertTo-Json | Set-Content "$base/config.json"
    $global:CLGrowTest_azureSize=512; $global:CLGrowTest_partitionSize=512GB-17MB; $global:CLGrowTest_free=40GB
    $global:CLGrowTest_patches=0; $global:CLGrowTest_resizes=0; $global:CLGrowTest_failRescan=$true
    $global:CLGrowTest_wrongOwner=$false; $global:CLGrowTest_busy=$false
    function Invoke-RestMethod {
        param($Uri,$Method,$Headers,$Body,$TimeoutSec,$ContentType,[switch]$UseBasicParsing)
        if ($Uri -like 'http://169.254.169.254/*') { return @{access_token='offline-token'} }
        Assert-True ($Uri -eq "https://management.azure.com$($s.DiskId)?api-version=2023-10-02") 'Unexpected Azure resource.'
        if ($Method -eq 'PATCH') {
            $payload=$Body | ConvertFrom-Json
            Assert-True (@($payload.PSObject.Properties).Count -eq 1) 'Unexpected PATCH field.'
            Assert-True (@($payload.properties.PSObject.Properties).Count -eq 1) 'Unexpected disk mutation.'
            $global:CLGrowTest_patches++; $global:CLGrowTest_azureSize=$payload.properties.diskSizeGB
        }
        return @{id=$s.DiskId;managedBy=$(if ($global:CLGrowTest_wrongOwner) {'other'} else {$s.VmId});sku=@{name=$s.DiskType};
            properties=@{uniqueId=$s.AzureDiskUniqueId;diskState='Attached';maxShares=1;diskSizeGB=$global:CLGrowTest_azureSize;provisioningState=$(if ($global:CLGrowTest_busy) {'Updating'} else {'Succeeded'})}}
    }
    function Get-Disk {
        param($Number)
        [pscustomobject]@{Number=2;UniqueId='test-disk';IsBoot=$false;IsSystem=$false;IsOffline=$false;IsReadOnly=$false;PartitionStyle='GPT';BusType='NVMe';Size=($global:CLGrowTest_azureSize*1GB)}
    }
    function Get-Partition { param($DriveLetter,$DiskNumber) [pscustomobject]@{DiskNumber=2;PartitionNumber=2;Type='Basic';Size=$global:CLGrowTest_partitionSize} }
    function Get-Volume { param($DriveLetter) [pscustomobject]@{FileSystem='NTFS';HealthStatus='Healthy';Size=$global:CLGrowTest_partitionSize;SizeRemaining=$global:CLGrowTest_free} }
    function Update-HostStorageCache { if ($global:CLGrowTest_failRescan) { throw 'Simulated interruption after PATCH.' } }
    function Get-PartitionSupportedSize { param($DiskNumber,$PartitionNumber) @{SizeMax=$global:CLGrowTest_azureSize*1GB-17MB} }
    function Resize-Partition { param($DiskNumber,$PartitionNumber,$Size,$ErrorAction) $global:CLGrowTest_resizes++; $global:CLGrowTest_partitionSize=$Size }
    function Write-EventLog { param($LogName,$Source,$EventId,$EntryType,$Message) }
    function Start-Sleep { param($Seconds) throw 'Unexpected polling in this fixture.' }
    $worker="$root/Scripts/Windows/Invoke-ImageDiskAutoGrow.ps1"
    Assert-Throws { & $worker }
    Assert-True ($global:CLGrowTest_patches -eq 1 -and $global:CLGrowTest_azureSize -eq 640) 'First grow intent.'
    Assert-True ((Get-Content -Raw "$base/journal.json" | ConvertFrom-Json).TargetGiB -eq 640) 'Pending target not persisted.'
    $global:CLGrowTest_failRescan=$false
    & $worker
    Assert-True ($global:CLGrowTest_patches -eq 1 -and $global:CLGrowTest_resizes -eq 1) 'Retry purchased a second growth step.'
    & $worker
    Assert-True ($global:CLGrowTest_patches -eq 1) 'Cooldown failed.'
    Set-Content "$base/paused" 'test'; & $worker
    Assert-True ($global:CLGrowTest_patches -eq 1) 'Paused task mutated disk.'
    Remove-Item "$base/paused"
    $global:CLGrowTest_wrongOwner=$true; Assert-Throws { & $worker }; $global:CLGrowTest_wrongOwner=$false
    $global:CLGrowTest_busy=$true; Assert-Throws { & $worker }; $global:CLGrowTest_busy=$false
    $global:CLGrowTest_azureSize=4096; $global:CLGrowTest_partitionSize=4096GB-17MB
    Assert-Throws { & $worker }
    Assert-True ($global:CLGrowTest_patches -eq 1) 'Cap or ownership guard permitted a PATCH.'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture=$oldWorkerCulture; $env:ProgramData=$oldProgramData; Remove-Item $temp -Recurse -Force; Get-Variable CLGrowTest_* -Scope Global | Remove-Variable -Scope Global }
Write-Output 'Offline guest crash recovery, no double-growth, cooldown, pause, ownership and capacity-cap tests passed.'
# Validate enabled WhatIf without Azure modules, authentication or state writes.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cloudlab-grow-plan-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path "$temp/Runbooks","$temp/Modules/CloudLab.Azure","$temp/Scripts/Windows","$temp/.local/config" -Force | Out-Null
    Copy-Item "$root/Runbooks/Set-LabAutoGrow.ps1" "$temp/Runbooks"
    foreach ($name in 'AutoGrow','Common','Lifecycle','AzureMonitor') { Copy-Item "$root/Modules/CloudLab.Azure/$name.psm1" "$temp/Modules/CloudLab.Azure" }
    Copy-Item "$root/Scripts/Windows/AutoGrow.Core.ps1" "$temp/Scripts/Windows"
    $lab=@'
@{
SubscriptionId='TEST-SUB';TenantId='TEST-TENANT';ProjectId='TEST-PROJECT'
ResourceGroup='rg-test';SharedResourceGroup='rg-retained';Location='germanywestcentral';Prefix='lab';VaultName='kv-offline';Environment='sandbox'
Export=@{StorageAccount='stoffline';Container='exports'};Backup=@{Enabled=$false}
App=@{Name='lab-app';OsDiskType='StandardSSD_LRS';DataDiskType='Standard_LRS';DiskGB=512}
Sql=@{OsDiskType='StandardSSD_LRS';DataDiskType='StandardSSD_LRS';DiskGB=32}
Keycloak=@{OsDiskType='StandardSSD_LRS'}
}
'@
    $lab=$lab.Replace('TEST-SUB',[guid]::NewGuid().ToString()).Replace('TEST-TENANT',[guid]::NewGuid().ToString()).Replace('TEST-PROJECT',[guid]::NewGuid().ToString())
    Set-Content "$temp/.local/config/lab.psd1" $lab
    $settings=(Get-Content -Raw "$root/Config/autogrow.example.psd1").Replace('Enabled = $false','Enabled = $true').Replace('DiskBindingReviewed = $false','DiskBindingReviewed = $true').Replace('REPLACE-reviewed-Windows-Get-Disk-UniqueId','test-binding')
    Set-Content "$temp/.local/config/autogrow.psd1" $settings
    & "$temp/Runbooks/Set-LabAutoGrow.ps1" -Mode Deploy -WhatIf
    Assert-True (-not (Test-Path "$temp/.local/state")) 'WhatIf wrote state.'
    $module=Import-Module "$temp/Modules/CloudLab.Azure/AutoGrow.psm1" -Force -PassThru
    & $module {
        function Get-AzDisk { param($ResourceGroupName,$DiskName,$ErrorAction) @{Id='test';UniqueId='test-unique';Sku=@{Name='Standard_LRS'};DiskSizeGB=640} }
        $c=@{ResourceGroup='test';App=@{Name='app';DiskGB=512}}
        $state=@{AutoGrow=@{DiskId='test';AzureDiskUniqueId='test-unique';DiskType='Standard_LRS';MaxSizeGiB=4096}}
        Sync-CLAutoGrowSize $c $state
        if ($c.App.DiskGB -ne 640) { throw 'Redeployment did not reconcile grown size.' }
        $state.AutoGrow.MaxSizeGiB=512
        $failed=$false; try { Sync-CLAutoGrowSize $c $state } catch { $failed=$true }
        if (-not $failed) { throw 'Reconciliation ignored maximum.' }
    }
} finally { Remove-Item $temp -Recurse -Force }
# Parse the generated guest-install and inspect scripts, not just their container.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Runbooks/Set-LabAutoGrow.ps1",[ref]$tokens,[ref]$errors)
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('$base=')},$true)) {
    $t=$null; $e=$null
    [Management.Automation.Language.Parser]::ParseInput($node.Value,[ref]$t,[ref]$e) | Out-Null
    Assert-True ($e.Count -eq 0) 'Generated guest payload does not parse.'
}
Write-Output 'Offline enabled WhatIf, grown-size reconciliation and guest payload parsing checks passed.'
