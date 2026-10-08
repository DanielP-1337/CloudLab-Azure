[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base=Join-Path $env:ProgramData 'CloudLab/AutoGrow'
. "$base/AutoGrow.Core.ps1"
$m=Enter-CLAutoGrowMutex
try {
    if (Test-Path "$base/paused") { return }
    if (Test-Path "$env:ProgramData/CloudLab/quiesce.json") { return }
    $s=Get-Content -Raw "$base/config.json" | ConvertFrom-Json
    Assert-CLAutoGrowSettings $s
    if (-not $s.Enabled) { return }
    $journalPath="$base/journal.json"
    $j=if (Test-Path $journalPath) { Get-Content -Raw $journalPath | ConvertFrom-Json } else { [pscustomobject]@{TargetGiB=0;LastAttemptUtc='';DiskId=$s.DiskId;DiskUniqueId=$s.AzureDiskUniqueId} }
    if ($j.DiskId -ne $s.DiskId -or $j.DiskUniqueId -ne $s.AzureDiskUniqueId) { throw 'Journal belongs to another disk.' }
    function Save-Journal {
        $j | ConvertTo-Json | Set-Content "$journalPath.tmp" -Encoding UTF8
        Move-Item "$journalPath.tmp" $journalPath -Force
    }
    function Disk-Request {
        param([string]$Method='GET',$Body=$null)
        $token=Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F'
        $args=@{Uri="https://management.azure.com$($s.DiskId)?api-version=2023-10-02";Method=$Method;Headers=@{Authorization="Bearer $($token.access_token)"};TimeoutSec=60;UseBasicParsing=$true}
        if ($Body) { $args.Body=$Body; $args.ContentType='application/json' }
        try { Invoke-RestMethod @args } finally { $token=$null }
    }
    $g=Get-CLAutoGrowVolume $s
    $a=Disk-Request
    if ($a.id -ne $s.DiskId -or $a.properties.uniqueId -ne $s.AzureDiskUniqueId -or $a.managedBy -ne $s.VmId -or
        $a.sku.name -ne $s.DiskType -or $a.properties.diskState -ne 'Attached' -or $a.properties.maxShares -gt 1 -or
        $a.properties.diskSizeGB -lt $s.InitialGiB -or $a.properties.diskSizeGB -gt $s.MaxSizeGiB) { throw 'Azure disk ownership/type/size mismatch.' }
    if ($a.properties.provisioningState -ne 'Succeeded') { throw 'Azure disk has an unfinished operation; retry later.' }
    $current=[int]$a.properties.diskSizeGB
    # Persist intent BEFORE PATCH; a timeout never authorizes another growth step.
    if ($j.TargetGiB -gt 0) {
        if ($j.TargetGiB -lt $current -or $j.TargetGiB -gt $s.MaxSizeGiB) { throw 'Pending target differs; manual review required.' }
        $target=[int]$j.TargetGiB
    } elseif ($g.Partition.Size -lt ($current*1GB-256MB)) {
        $target=$current # Repair guest expansion before considering another billable step.
        $j.TargetGiB=$target; Save-Journal
    } else {
        if (-not (Test-CLAutoGrowPressure $s $g.Volume.Size $g.Volume.SizeRemaining)) { return }
        if ($current -ge $s.MaxSizeGiB) { throw 'Configured capacity limit reached; operator action required.' }
        if ($j.LastAttemptUtc -and ([DateTimeOffset]::UtcNow-(ConvertTo-CLAutoGrowUtc $j.LastAttemptUtc)).TotalMinutes -lt $s.CooldownMinutes) { return }
        $target=Get-CLAutoGrowTarget $s $current
        $j.TargetGiB=$target; $j.LastAttemptUtc=[DateTimeOffset]::UtcNow.ToString('o'); Save-Journal
    }
    if ($target -gt $current) {
        Disk-Request PATCH (@{properties=@{diskSizeGB=$target}} | ConvertTo-Json -Compress) | Out-Null
    }
    $ready=$false
    for ($i=0;$i -lt 40;$i++) {
        $a=Disk-Request
        if ($a.properties.uniqueId -ne $s.AzureDiskUniqueId -or $a.managedBy -ne $s.VmId -or $a.properties.diskSizeGB -gt $target) { throw 'Disk changed during growth.' }
        if ($a.properties.provisioningState -eq 'Failed') { throw 'Azure expansion failed.' }
        Update-HostStorageCache
        $g=Get-CLAutoGrowVolume $s
        if ($a.properties.provisioningState -eq 'Succeeded' -and $a.properties.diskSizeGB -eq $target -and $g.Disk.Size -ge $target*1GB-1MB) { $ready=$true; break }
        Start-Sleep -Seconds 15
    }
    if (-not $ready) { throw 'Expansion pending; next run reconciles the SAME target.' }
    $supported=Get-PartitionSupportedSize -DiskNumber $g.Disk.Number -PartitionNumber $g.Partition.PartitionNumber
    if ($supported.SizeMax -gt $target*1GB -or $supported.SizeMax -lt $target*1GB-256MB) { throw 'Unexpected supported partition size.' }
    if ($g.Partition.Size -lt $supported.SizeMax) { Resize-Partition -DiskNumber $g.Disk.Number -PartitionNumber $g.Partition.PartitionNumber -Size $supported.SizeMax -ErrorAction Stop }
    $g=Get-CLAutoGrowVolume $s
    if ($g.Partition.Size -lt $target*1GB-256MB) { throw 'Volume expansion verification failed.' }
    $j.TargetGiB=0; Save-Journal
    Write-EventLog -LogName Application -Source CloudLabAutoGrow -EventId 100 -EntryType Information -Message "Image data disk expanded/reconciled to $target GiB."
} catch {
    Write-EventLog -LogName Application -Source CloudLabAutoGrow -EventId 101 -EntryType Error -Message 'Image disk auto-grow failed or reached its limit. Inspect protected task configuration, journal and Azure Activity Log. No automatic shutdown or shrink was attempted.'
    throw 'Auto-grow failed; inspect the protected journal and Azure Activity Log.'
} finally { $m.ReleaseMutex(); $m.Dispose() }
