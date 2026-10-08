$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../Scripts/Windows/AutoGrow.Core.ps1"
function Read-CLAutoGrow {
    param([string]$Root)
    $path=Join-Path $Root '.local/config/autogrow.psd1'
    if (-not (Test-Path $path)) { return @{Enabled=$false} }
    $s=Import-PowerShellDataFile $path
    Assert-CLAutoGrowSettings $s
    return $s
}
function Set-CLAutoGrowPause {
    param($Config,$State,[bool]$Paused=$true)
    if (-not $State.ContainsKey('AutoGrow')) { return }
    $vms=@(Get-AzVM -ResourceGroupName $Config.ResourceGroup | Where-Object Name -eq $Config.App.Name)
    if ($vms.Count -eq 0) { if (-not $Paused) { throw 'Cannot resume a missing app VM.' }; return } # A partial destroy may already have removed the VM.
    if ($vms.Count -ne 1) { throw 'Ambiguous app VM.' }
    $action=if ($Paused) { "Set-Content -LiteralPath (`$base+'/paused') -Value 'Paused by lifecycle'" } else { "Remove-Item -LiteralPath (`$base+'/paused') -Force -ErrorAction SilentlyContinue" }
    $body=@'
$base=Join-Path $env:ProgramData 'CloudLab/AutoGrow'
New-Item -ItemType Directory -Path $base -Force | Out-Null
$m=New-Object Threading.Mutex($false,'Global\CloudLabImageDiskGrow')
try { $held=$m.WaitOne([TimeSpan]::FromMinutes(15)) } catch [Threading.AbandonedMutexException] { $held=$true }
if (-not $held) { $m.Dispose(); throw 'Auto-grow busy; lifecycle aborted.' }
try {
__ACTION__
} finally { $m.ReleaseMutex(); $m.Dispose() }
'@
    Invoke-CLGuest $Config $Config.App.Name ($body.Replace('__ACTION__',$action)) Windows
}
function Sync-CLAutoGrowSize {
    param($Config,$State)
    if (-not $State.ContainsKey('AutoGrow')) { return }
    $s=$State.AutoGrow
    $d=Get-AzDisk -ResourceGroupName $Config.ResourceGroup -DiskName "$($Config.App.Name)-data" -ErrorAction Stop
    if ($d.Id -ne $s.DiskId -or $d.UniqueId -ne $s.AzureDiskUniqueId -or $d.Sku.Name -ne $s.DiskType -or
        $d.DiskSizeGB -lt $Config.App.DiskGB -or $d.DiskSizeGB -gt $s.MaxSizeGiB) { throw 'Grown disk differs from deployment receipt.' }
    # Runtime only: never request a shrink on re-deployment. Fresh deployments retain original size.
    $Config.App.DiskGB=[int]$d.DiskSizeGB
}
function Remove-CLAutoGrowRole {
    param($Config,$State)
    if (-not $State.ContainsKey('AutoGrow')) { return }
    $s=$State.AutoGrow
    foreach ($pair in @(@($s.AssignmentId,'2022-04-01'),@($s.RoleId,'2022-04-01'))) {
        try { $get=Invoke-AzRestMethod -Method GET -Path "$($pair[0])?api-version=$($pair[1])" }
        catch { if ($_.Exception.Response.StatusCode -eq 404) { continue }; throw }
        if ($get.StatusCode -eq 404) { continue }
        if ($get.StatusCode -ne 200) { throw 'Cannot verify auto-grow RBAC ownership.' }
        $obj=$get.Content | ConvertFrom-Json
        if ($pair[0] -eq $s.AssignmentId) {
            if ($obj.properties.principalId -ne $s.PrincipalId -or $obj.properties.roleDefinitionId -ne $s.RoleId) { throw 'Auto-grow assignment ownership mismatch.' }
        } elseif ($obj.properties.roleName -ne $s.RoleName) { throw 'Auto-grow role ownership mismatch.' }
        $delete=Invoke-AzRestMethod -Method DELETE -Path "$($pair[0])?api-version=$($pair[1])"
        if ($delete.StatusCode -notin @(200,204)) { throw 'Auto-grow RBAC cleanup failed.' }
    }
}
Export-ModuleMember -Function *-CL*
