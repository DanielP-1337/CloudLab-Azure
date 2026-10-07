#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module "$root/Modules/CloudLab.Azure/HealthRecovery.psm1" -Force
$path=Join-Path $root '.local/config/lab.psd1'
$c=Import-PowerShellDataFile -LiteralPath $path
Assert-CLHealthRecoveryProfile $c
if ($c.Export.SqlPreparePath) { throw 'A custom SQL export wrapper is configured; review it before selecting HealthNative.' }
$text=Get-Content -Raw -LiteralPath $path
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Invalid config syntax.' }
$top=$ast.Find({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)
$edits=@();$nl=if ($text.Contains("`r`n")) {"`r`n"} else {"`n"}
foreach ($section in 'App','Export') {
    $pairs=@($top.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq $section })
    if ($pairs.Count -ne 1) { throw 'Expected one configuration section.' }
    $table=$pairs[0].Item2.Find({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)
    $settings=if ($section -eq 'App') { @{QuiesceReviewed='$true'} } else { @{SqlMode="'HealthNative'";SqlPreparePath="''";SqlPrepareSha256="''"} }
    foreach ($key in $settings.Keys) {
        $pair=@($table.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -eq $key })
        if ($pair.Count -gt 1) { throw 'Duplicate config key.' }
        if ($pair.Count) {
            $e=$pair[0].Item2.Extent;$edits+=@{Start=$e.StartOffset;Length=$e.EndOffset-$e.StartOffset;Text=$settings[$key]}
        } else { $edits+=@{Start=$table.Extent.StartOffset+2;Length=0;Text=$nl+"        $key = $($settings[$key])"+$nl} }
    }
}
foreach ($e in $edits | Sort-Object Start -Descending) { $text=$text.Remove($e.Start,$e.Length).Insert($e.Start,$e.Text) }
Write-Output 'Reviewed profile: dedicated health IIS site/pool, diagnostics task, no WriterServices, SQL Agent stopped, no active SQL user transactions; external writers are not covered.'
if (-not $PSCmdlet.ShouldProcess($path,'Enable the reviewed synthetic health export profile and native backup/restore proof; create local config backup')) { return }
$tmp="$path.recovery.tmp.psd1"
try {
    [IO.File]::WriteAllText($tmp,$text,[Text.UTF8Encoding]::new($false))
    $candidate=Import-PowerShellDataFile -LiteralPath $tmp
    Assert-CLHealthRecoveryProfile $candidate
    if ((Get-Content -Raw $path) -cne $text) {
        Copy-Item $path "$path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
Write-Output 'Local native health recovery profile configured. No Azure operation performed.'
