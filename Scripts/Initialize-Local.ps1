[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach ($name in 'config','state','results','certificates','installers') {
    New-Item -ItemType Directory -Path "$root/.local/$name" -Force | Out-Null
}
$path="$root/.local/config/lab.psd1"
if (-not (Test-Path $path)) {
    $text=Get-Content -Raw "$root/Config/lab.example.psd1"
    $text.Replace('REPLACE-local-project-guid',[guid]::NewGuid().ToString()) | Set-Content $path
}
$terms="$root/.local/private-terms.txt"
if (-not (Test-Path $terms)) {
    Set-Content $terms '# One private employer/product/domain/name per line. Local only. Fill before public release.'
}
Write-Output "Edit $path and .local/private-terms.txt. No Azure operation was performed."
