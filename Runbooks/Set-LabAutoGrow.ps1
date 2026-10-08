[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Deploy','Pause','Resume','Remove','Inspect')][string]$Mode='Inspect',
    [string]$ConfigPath="$PSScriptRoot/../.local/config/lab.psd1",[switch]$EnableBillableResources)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach ($name in 'Common','Lifecycle','AutoGrow') { Import-Module "$root/Modules/CloudLab.Azure/$name.psm1" -Force }
$c=Read-CLConfig $ConfigPath
$s=if ($Mode -in @('Deploy','Resume')) { Read-CLAutoGrow $root } else { @{Enabled=$false} }
if ($Mode -eq 'Deploy' -and -not $s.Enabled) { Write-Output 'Auto-grow disabled locally. No Azure operation performed.'; return }
if ($Mode -in @('Deploy','Resume')) {
    Write-Warning 'COST NOTICE: Enables unattended, irreversible image-disk growth up to the reviewed cap. Higher disk tiers incur ongoing charges. Budget emails are NOT a spending cap.'
    if (-not $EnableBillableResources -and -not $WhatIfPreference) { throw 'Use -EnableBillableResources after reviewing costs.' }
}
if ($Mode -ne 'Inspect' -and -not $PSCmdlet.ShouldProcess($c.App.Name,"Auto-grow $Mode")) { return }
foreach ($name in 'Az.Accounts','Az.Resources','Az.Compute') { Import-Module $name }
$ctx=Get-AzContext
if (-not $ctx -or $ctx.Subscription.Id -ne $c.SubscriptionId -or $ctx.Tenant.Id -ne $c.TenantId) { throw 'Sign in to the configured subscription first.' }
$lock=Enter-CLLifecycleLock $c $root
try {
    $state=Read-CLState $c $root
    Assert-CLGroup $c $state (Get-CLGroup $c.ResourceGroup)
    $path=Get-CLStatePath $c $root
    if ($Mode -eq 'Inspect') {
        $vm=Get-AzVM -ResourceGroupName $c.ResourceGroup -Name $c.App.Name
        $disk=Get-AzDisk -ResourceGroupName $c.ResourceGroup -DiskName "$($c.App.Name)-data"
        [pscustomobject]@{AzureDiskId=$disk.Id;AzureDiskUniqueId=$disk.UniqueId;SizeGiB=$disk.DiskSizeGB;Lun0DiskId=($vm.StorageProfile.DataDisks | Where-Object Lun -eq 0).ManagedDisk.Id} | Format-List
        # Executes a read-only guest query; VM runtime remains billable.
        $body=@'
$base=Join-Path $env:ProgramData 'CloudLab/AutoGrow'
Get-Disk | Select-Object Number,UniqueId,SerialNumber,Size,PartitionStyle,BusType,Location,IsBoot,IsSystem | ConvertTo-Json
Get-Partition | Select-Object DiskNumber,PartitionNumber,DriveLetter,Size,Type | ConvertTo-Json
Get-ScheduledTask -TaskName CloudLabImageDiskAutoGrow -ErrorAction SilentlyContinue | Select-Object State | ConvertTo-Json
if (Test-Path "$base/journal.json") { Get-Content "$base/journal.json" }
"Paused: $(Test-Path "$base/paused")"
'@
        $result=Invoke-AzVMRunCommand -ResourceGroupName $c.ResourceGroup -VMName $c.App.Name -CommandId RunPowerShellScript -ScriptString $body
        $result.Value.Message
        return
    }
    if ($Mode -eq 'Pause') { Set-CLAutoGrowPause $c $state; return }
    if ($Mode -eq 'Remove') {
        Set-CLAutoGrowPause $c $state
        Invoke-CLGuest $c $c.App.Name "Unregister-ScheduledTask -TaskName CloudLabImageDiskAutoGrow -Confirm:`$false -ErrorAction SilentlyContinue" Windows
        Remove-CLAutoGrowRole $c $state
        if ($state.ContainsKey('AutoGrow')) { $state.AutoGrow.Installed=$false; Save-CLState $state $path }
        # Keep receipt for grown-size reconciliation. No shrink, no removal of audit journal.
        return
    }
    Assert-CLNotInMaintenance $state
    if ($state.Status -ne 'Deployed') { throw 'Deploy the lab successfully first.' }
    if ($Mode -eq 'Resume') {
        if (-not $s.Enabled -or -not $state.ContainsKey('AutoGrow') -or -not $state.AutoGrow.Installed) { throw 'Deploy enabled auto-grow first.' }
        $hash=(Get-FileHash "$root/.local/config/autogrow.psd1" -Algorithm SHA256).Hash
        if ($hash -ne $state.AutoGrow.ConfigHash) { throw 'Local settings changed; deploy them before resuming.' }
        $state.Export=$null; Save-CLState $state $path
        Set-CLAutoGrowPause $c $state $false
        return
    }
    $vm=Get-AzVM -ResourceGroupName $c.ResourceGroup -Name $c.App.Name
    $attached=@($vm.StorageProfile.DataDisks | Where-Object Lun -eq 0)
    $disk=Get-AzDisk -ResourceGroupName $c.ResourceGroup -DiskName "$($c.App.Name)-data"
    if ($attached.Count -ne 1 -or $attached[0].ManagedDisk.Id -ne $disk.Id -or $disk.ManagedBy -ne $vm.Id -or
        $disk.Sku.Name -ne $c.App.DataDiskType -or $disk.DiskSizeGB -gt $s.MaxSizeGiB -or $disk.DiskSizeGB -lt $c.App.DiskGB -or
        $disk.MaxShares -gt 1 -or -not $vm.Identity.PrincipalId -or -not $disk.UniqueId -or $c.App.DriveLetter -notmatch '^[D-Z]$') { throw 'App data disk identity/type/limit mismatch.' }
    Set-CLAutoGrowPause $c $state
    if ($state.ContainsKey('AutoGrow')) {
        if ($state.AutoGrow.DiskId -ne $disk.Id -or $state.AutoGrow.AzureDiskUniqueId -ne $disk.UniqueId) { throw 'Disk replacement requires explicit removal and fresh enrollment.' }
    } else {
        $roleGuid=[guid]::NewGuid().ToString()
        $state.AutoGrow=@{DiskId=$disk.Id;AzureDiskUniqueId=$disk.UniqueId;DiskType=$disk.Sku.Name;PrincipalId=[string]$vm.Identity.PrincipalId;
            RoleId="/subscriptions/$($c.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$roleGuid";
            RoleName="CloudLab image grow $($c.ProjectId)";
            AssignmentId="$($disk.Id)/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"}
    }
    $a=$state.AutoGrow
    if ($a.PrincipalId -ne [string]$vm.Identity.PrincipalId) { throw 'VM identity changed; review existing grant.' }
    $a.Installed=$false
    $a.MaxSizeGiB=$s.MaxSizeGiB
    $a.ConfigHash=(Get-FileHash "$root/.local/config/autogrow.psd1" -Algorithm SHA256).Hash
    $state.Export=$null; Save-CLState $state $path # Receipt before any RBAC side effect.
    $s.DiskId=$disk.Id; $s.AzureDiskUniqueId=$disk.UniqueId; $s.VmId=$vm.Id; $s.DiskType=$disk.Sku.Name
    $s.InitialGiB=[int]$c.App.DiskGB; $s.DriveLetter=$c.App.DriveLetter
    $json=$s | ConvertTo-Json -Depth 8 -Compress
    $config64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $core64=[Convert]::ToBase64String([IO.File]::ReadAllBytes("$root/Scripts/Windows/AutoGrow.Core.ps1"))
    $worker64=[Convert]::ToBase64String([IO.File]::ReadAllBytes("$root/Scripts/Windows/Invoke-ImageDiskAutoGrow.ps1"))
    $body=@'
$base=Join-Path $env:ProgramData 'CloudLab/AutoGrow'
New-Item -ItemType Directory -Path $base -Force | Out-Null
if ((Get-Item -LiteralPath $base).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Auto-grow directory must not be a reparse point.' }
$existing=@(Get-ChildItem -LiteralPath $base -Force -Recurse)
if (@($existing | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Unexpected reparse point in auto-grow directory.' }
# Restrict scripts, settings and journal to SYSTEM and local Administrators.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
    $id=New-Object Security.Principal.SecurityIdentifier($sid)
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($id,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $base -AclObject $acl
foreach ($file in @($existing | Where-Object { -not $_.PSIsContainer })) {
    $fileAcl=New-Object Security.AccessControl.FileSecurity
    $fileAcl.SetAccessRuleProtection($true,$false)
    $fileAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))
    foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
        $fileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','Allow')))
    }
    Set-Acl -LiteralPath $file.FullName -AclObject $fileAcl
}
Set-Content "$base/paused" 'Deployment pending'
[IO.File]::WriteAllBytes("$base/AutoGrow.Core.ps1",[Convert]::FromBase64String('__CORE__'))
. "$base/AutoGrow.Core.ps1"
$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG__')) | ConvertFrom-Json
Assert-CLAutoGrowSettings $s
Get-CLAutoGrowVolume $s | Out-Null
$s | ConvertTo-Json -Depth 8 | Set-Content "$base/config.json" -Encoding UTF8
[IO.File]::WriteAllBytes("$base/Invoke-ImageDiskAutoGrow.ps1",[Convert]::FromBase64String('__WORKER__'))
if (-not [Diagnostics.EventLog]::SourceExists('CloudLabAutoGrow')) { New-EventLog -LogName Application -Source CloudLabAutoGrow }
$exe="$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe"
$action=New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$base+'\Invoke-ImageDiskAutoGrow.ps1"')
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes($s.CheckMinutes))
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(20))
Register-ScheduledTask -TaskName CloudLabImageDiskAutoGrow -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
'@
    $body=$body.Replace('__CORE__',$core64).Replace('__CONFIG__',$config64).Replace('__WORKER__',$worker64)
    Invoke-CLGuest $c $c.App.Name $body Windows
    $role=@{properties=@{roleName=$a.RoleName;description='Read and resize one reviewed image disk. Assignment is restricted to that disk.';type='CustomRole';
        permissions=@(@{actions=@('Microsoft.Compute/disks/read','Microsoft.Compute/disks/write');notActions=@();dataActions=@();notDataActions=@()});
        assignableScopes=@("/subscriptions/$($c.SubscriptionId)/resourceGroups/$($c.ResourceGroup)")}}
    $assignment=@{properties=@{principalId=$a.PrincipalId;principalType='ServicePrincipal';roleDefinitionId=$a.RoleId}}
    foreach ($op in @(@($a.RoleId,$role),@($a.AssignmentId,$assignment))) {
        $result=Invoke-AzRestMethod -Method PUT -Path "$($op[0])?api-version=2022-04-01" -Payload ($op[1] | ConvertTo-Json -Depth 10 -Compress)
        if ($result.StatusCode -notin @(200,201)) { throw 'Auto-grow RBAC deployment failed; task remains paused.' }
    }
    $a.Installed=$true; Save-CLState $state $path
    Write-Output 'Auto-grow installed PAUSED. Review Inspect output, then explicitly Resume. RBAC propagation can take several minutes.'
} finally { $lock.Dispose() }
