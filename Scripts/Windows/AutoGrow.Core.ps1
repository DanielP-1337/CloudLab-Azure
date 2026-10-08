# PowerShell 5.1 compatible; shared by offline tests and the VM task.
function Assert-CLAutoGrowSettings {
    param($Settings)
    if ($Settings.Enabled -isnot [bool]) { throw 'Enabled must be Boolean.' }
    if (-not $Settings.Enabled) { return }
    foreach ($entry in @(@('GrowthPercent',1,100),@('GrowthMiB',1,4194304),@('MaxSizeGiB',32,4096),@('FreePercent',1,80),@('FreeGiB',1,2048),@('CheckMinutes',1,60),@('CooldownMinutes',5,1440))) {
        $n=0
        if (-not [int]::TryParse([string]$Settings.($entry[0]),[ref]$n) -or $n -lt $entry[1] -or $n -gt $entry[2]) { throw "Invalid auto-grow setting: $($entry[0])" }
    }
    if ($Settings.GrowthMode -notin @('Percent','FixedMiB')) { throw 'Use Percent or FixedMiB.' }
    if ($Settings.FreeGiB -ge $Settings.MaxSizeGiB) { throw 'FreeGiB must be below MaxSizeGiB.' }
    if ($Settings.DiskBindingReviewed -isnot [bool] -or -not $Settings.DiskBindingReviewed -or
        [string]::IsNullOrWhiteSpace($Settings.GuestDiskUniqueId) -or $Settings.GuestDiskUniqueId -match 'REPLACE') { throw 'Review and bind the Windows data-disk UniqueId first.' }
}
function Get-CLAutoGrowTarget {
    param($Settings,[int]$CurrentGiB)
    if ($CurrentGiB -lt 1 -or $CurrentGiB -gt $Settings.MaxSizeGiB) { throw 'Current size outside reviewed limit.' }
    $step=if ($Settings.GrowthMode -eq 'Percent') { [math]::Ceiling($CurrentGiB*$Settings.GrowthPercent/100.0) } else { [math]::Ceiling($Settings.GrowthMiB/1024.0) }
    [int][math]::Min($Settings.MaxSizeGiB,$CurrentGiB+[math]::Max(1,$step))
}
function Test-CLAutoGrowPressure {
    param($Settings,[double]$SizeBytes,[double]$FreeBytes)
    if ($SizeBytes -le 0 -or $FreeBytes -lt 0 -or $FreeBytes -gt $SizeBytes) { throw 'Invalid live volume measurement.' }
    ($FreeBytes*100/$SizeBytes -le $Settings.FreePercent -or $FreeBytes/1GB -le $Settings.FreeGiB)
}
function Get-CLAutoGrowVolume {
    param($Settings)
    $p=Get-Partition -DriveLetter $Settings.DriveLetter -ErrorAction Stop
    $d=Get-Disk -Number $p.DiskNumber -ErrorAction Stop
    $v=Get-Volume -DriveLetter $Settings.DriveLetter -ErrorAction Stop
    if ($d.UniqueId -ne $Settings.GuestDiskUniqueId -or $d.IsBoot -or $d.IsSystem -or $d.IsOffline -or $d.IsReadOnly -or
        $d.PartitionStyle -ne 'GPT' -or $v.FileSystem -ne 'NTFS' -or $v.HealthStatus -ne 'Healthy' -or $d.BusType -notin @('SCSI','NVMe')) { throw 'Guest disk binding/layout/health mismatch.' }
    $basic=@(Get-Partition -DiskNumber $d.Number | Where-Object Type -eq 'Basic')
    if ($basic.Count -ne 1 -or $basic[0].PartitionNumber -ne $p.PartitionNumber) { throw 'Expected one basic NTFS data partition; no Storage Spaces/dynamic/striped volumes.' }
    @{Partition=$p;Disk=$d;Volume=$v}
}
function Enter-CLAutoGrowMutex {
    $m=New-Object Threading.Mutex($false,'Global\CloudLabImageDiskGrow')
    try { $held=$m.WaitOne([TimeSpan]::FromMinutes(15)) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { $m.Dispose(); throw 'Auto-grow is busy; maintenance must not proceed.' }
    return $m
}

function ConvertTo-CLAutoGrowUtc {
    param([Parameter(Mandatory)]$Value)
    # PS 7 JSON may return DateTime; PS 5.1 may leave an ISO string.
    # Never coerce a typed date to culture-dependent text before parsing.
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw 'Ambiguous journal timestamp; UTC or explicit offset required.' }
        return [DateTimeOffset]::new($Value.ToUniversalTime())
    }
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw 'Invalid journal timestamp; an ISO timestamp with timezone is required.'
    }
    return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None).ToUniversalTime()
}
