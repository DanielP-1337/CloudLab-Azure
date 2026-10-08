@{
    # Copy to .local/config/monitoring.psd1. Never put real recipients here.
    Enabled = $false
    EmailReceivers = @()
    SampleSeconds = 60
    RetentionDays = 30
    DailyCapGB = 0.1 # Ingestion guardrail, NOT a spending limit; reaching it creates gaps.
    MissingMinutes = 15
    FreePercent = 10
    FreeGiB = 3
    # Alert when either free-space threshold is crossed. Per-role overrides are optional.
    DiskOverrides = @{}
    WindowsVolumes = @('C:', 'F:')
    LinuxVolumes = @('/')
    # Rules deploy disabled. Enable explicitly after Test-LabMonitoring passes.
}
