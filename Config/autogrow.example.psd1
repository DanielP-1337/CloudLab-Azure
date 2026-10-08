@{
    Enabled = $false
    GrowthMode = 'Percent' # Percent or FixedMiB
    GrowthPercent = 25
    GrowthMiB = 65536 # 64 GiB; used only in FixedMiB mode
    MaxSizeGiB = 4096
    FreePercent = 20
    FreeGiB = 50 # Grow if EITHER threshold is reached
    CheckMinutes = 5
    CooldownMinutes = 30
    # Bind the Windows volume to the Azure LUN-0 data disk after deployment.
    GuestDiskUniqueId = 'REPLACE-reviewed-Windows-Get-Disk-UniqueId'
    DiskBindingReviewed = $false
}
