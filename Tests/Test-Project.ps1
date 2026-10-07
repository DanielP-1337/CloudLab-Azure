[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$issues=@()
Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1','.psd1' -and $_.FullName -notmatch '[\\/]\.local[\\/]' } | ForEach-Object {
    $tokens=$null; $parseErrors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
    $issues+=@($parseErrors | ForEach-Object { $_.ToString() })
}
Import-PowerShellDataFile "$ProjectRoot/Config/lab.example.psd1" | Out-Null
Get-Content -Raw "$ProjectRoot/Templates/gateway.json" | ConvertFrom-Json | Out-Null
if ($issues.Count) { throw ($issues -join "`n") }
Write-Output 'PowerShell parser, public PSD1 and JSON validation passed. No Azure resource was changed.'
