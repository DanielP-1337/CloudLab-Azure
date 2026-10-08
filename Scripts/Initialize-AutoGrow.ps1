[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$path=Join-Path $root '.local/config/autogrow.psd1'
if (Test-Path $path) { Write-Output 'Local auto-grow config exists; no change.'; return }
if ($PSCmdlet.ShouldProcess($path,'Create disabled local image-disk auto-grow config')) {
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    Copy-Item "$root/Config/autogrow.example.psd1" $path
    Write-Output 'Local auto-grow config created, disabled. No Azure operation performed.'
}
