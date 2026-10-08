#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$path=Join-Path $root '.local/config/monitoring.psd1'
if (Test-Path -LiteralPath $path) { Write-Output 'Local monitoring config already exists; no change.'; return }
if ($PSCmdlet.ShouldProcess($path,'Copy disabled monitoring example to local config')) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Copy-Item -LiteralPath "$root/Config/monitoring.example.psd1" -Destination $path
    Write-Output 'Edit .local/config/monitoring.psd1 locally. No Azure operation performed.'
}
