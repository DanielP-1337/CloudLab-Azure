#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([switch]$UseMonitoringRecipients)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$path=Join-Path $root '.local/config/budget.psd1'
if (Test-Path -LiteralPath $path) { Write-Output 'Local budget config exists; no change.';return }
$text=Get-Content "$root/Config/budget.example.psd1" -Raw
$start=[DateTime]::UtcNow.Date.AddDays(1-[DateTime]::UtcNow.Day)
$text=$text.Replace('REPLACE-first-day-of-current-month',$start.ToString('yyyy-MM-dd')).Replace('REPLACE-expiration-date',$start.AddYears(1).ToString('yyyy-MM-dd'))
if ($UseMonitoringRecipients) {
    $m=Import-PowerShellDataFile "$root/.local/config/monitoring.psd1"
    if (@($m.EmailReceivers).Count -eq 0) { throw 'No local monitoring recipients to copy.' }
    $quoted=@($m.EmailReceivers | ForEach-Object { "'"+([string]$_).Replace("'","''")+"'" }) -join ', '
    $text=$text.Replace('EmailReceivers = @()',"EmailReceivers = @($quoted)")
}
if ($PSCmdlet.ShouldProcess($path,'Create disabled local budget config; optionally copy local monitoring recipients')) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -LiteralPath $path -Value $text -Encoding utf8
    Write-Output 'Local budget config created, disabled. Set amount, review currency and enable locally. No Azure operation performed.'
}
