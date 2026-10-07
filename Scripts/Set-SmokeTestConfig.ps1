# Local-only, pre-deployment migration. No Az commands or network access.
[CmdletBinding(SupportsShouldProcess)]
param([string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.local/config/lab.psd1'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$localRoot = [IO.Path]::GetFullPath((Join-Path $root '.local/config')) + [IO.Path]::DirectorySeparatorChar
$path = (Resolve-Path -LiteralPath $ConfigPath).Path
if (-not $path.StartsWith($localRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Only this project local configuration directory is allowed.'
}
$config = Import-PowerShellDataFile -LiteralPath $path
# Deliberately refuse all existing lifecycle state, even a completed deployment.
if (Get-ChildItem -LiteralPath (Join-Path $root '.local/state') -Filter '*.json' -File -ErrorAction SilentlyContinue) {
    throw 'Lifecycle state exists. This helper is only for a lab that has never been deployed. Do not delete state to bypass this guard.'
}
$original = [IO.File]::ReadAllText($path)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($original, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Configuration has parser errors.' }
$tables = @($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.HashtableAst]}, $true))
if ($tables.Count -eq 0) { throw 'No configuration hashtable found.' }
$top = $tables[0]
$updates = @{
    Root = @{ Location = 'germanywestcentral' }
    Keycloak = @{ Size = 'Standard_D2as_v6'; OsDiskType = 'StandardSSD_LRS' }
    App = @{ Size = 'Standard_D2as_v6'; OsDiskType = 'StandardSSD_LRS'; DataDiskType = 'Standard_LRS'; DiskGB = 512 }
    Sql = @{ Size = 'Standard_D2as_v6'; OsDiskType = 'StandardSSD_LRS'; DataDiskType = 'StandardSSD_LRS'; DiskGB = 32; MaxMemoryMB = 4096 }
}
$edits = @()
$newline = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
foreach ($section in $updates.Keys) {
    $table = $top
    if ($section -ne 'Root') {
        $pairs = @($top.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq $section })
        if ($pairs.Count -ne 1) { throw "Expected one section: $section" }
        $table = $pairs[0].Item2.Find({param($node) $node -is [System.Management.Automation.Language.HashtableAst]}, $true)
        if (-not $table) { throw "Expected a hashtable for $section." }
    }
    $insertions = @()
    foreach ($key in $updates[$section].Keys) {
        $value = $updates[$section][$key]
        $literal = if ($value -is [string]) { "'$value'" } else { [string]$value }
        $pairs = @($table.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq $key })
        if ($pairs.Count -gt 1) { throw "Duplicate setting: $section.$key" }
        if ($pairs.Count -eq 1) {
            $extent = $pairs[0].Item2.Extent
            $edits += @{ Start=$extent.StartOffset; Length=$extent.EndOffset-$extent.StartOffset; Text=$literal }
        } else {
            $insertions += "        $key = $literal"
        }
    }
    if ($insertions.Count) {
        $edits += @{ Start=$table.Extent.StartOffset+2; Length=0; Text=$newline+($insertions -join $newline)+$newline }
    }
}
$updated = $original
foreach ($edit in $edits | Sort-Object Start -Descending) {
    $updated = $updated.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
}
if ($updated -eq $original) { Write-Output 'Smoke-test settings already match. No file changed.'; return }
if (-not $PSCmdlet.ShouldProcess($path, 'Set Frankfurt smoke-test VM sizes and disk types; create a local backup')) { return }
$candidate = "$path.candidate.psd1"
if (Test-Path -LiteralPath $candidate) { throw 'Candidate file already exists. Review it before retrying.' }
try {
    [IO.File]::WriteAllText($candidate, $updated, [Text.UTF8Encoding]::new($false))
    Import-Module "$root/Modules/CloudLab.Azure/Common.psm1" -Force
    $checked = Read-CLConfig -Path $candidate
    foreach ($key in 'SubscriptionId','TenantId','ProjectId','ResourceGroup','SharedResourceGroup','Environment') {
        if ($checked[$key] -ne $config[$key]) { throw "Unrelated setting changed: $key" }
    }
    $backup = "$path.$([guid]::NewGuid().ToString('N')).bak"
    Copy-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
    Move-Item -LiteralPath $candidate -Destination $path -Force
    Write-Output 'Local Frankfurt smoke-test settings updated. Backup retained in .local/config. No Azure operation was performed.'
} finally {
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate }
}
