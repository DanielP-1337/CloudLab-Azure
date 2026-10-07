[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$repo=git -C $root rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) { throw 'Initialize a NEW Git repository in this folder first.' }
if ([IO.Path]::GetFullPath($repo.Trim()) -ne [IO.Path]::GetFullPath($root)) { throw 'This project must be the repository root.' }
$existing=git -C $root config --local --get core.hooksPath
if ($existing -and $existing.Trim() -ne '.githooks') { throw 'Existing hooks configuration detected; merge manually.' }
git -C $root config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw 'Could not install hooks.' }
python "$root/Scripts/check_public.py" --require-private-terms
if ($LASTEXITCODE -ne 0) { throw 'Public-content review failed.' }
Write-Output 'Local hooks enabled. CI cannot prevent a first public disclosure; keep the local checks enabled.'
