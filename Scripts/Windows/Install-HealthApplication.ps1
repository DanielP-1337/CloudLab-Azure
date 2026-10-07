# Executed inside the application VM by the application deployment stage.
# The host validates this lock before invoking any guest operation.
$release = $CL.App.HealthRelease
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Health installation requires 64-bit Windows PowerShell 5.1.' }
$packageDir = Join-Path $env:ProgramData ('CloudLab/Packages/' + $release.Tag)
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
$zip = Join-Path $packageDir $release.Asset
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri $release.Url -OutFile $zip
if ((Get-Item -LiteralPath $zip).Length -ne $release.Size -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $release.Sha256) { throw 'Health ZIP size/SHA-256 mismatch. No package code was executed.' }
$extract = Join-Path $packageDir ([guid]::NewGuid().ToString('N'))
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $total = 0L
        foreach ($entry in $archive.Entries) {
            $total += $entry.Length
            if ($entry.FullName -match '(^[/\\]|:|(^|[/\\])\.\.([/\\]|$))' -or $total -gt 200MB) { throw 'Unsafe or oversized release archive.' }
        }
    } finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    $installers = @(Get-ChildItem -LiteralPath $extract -Recurse -Filter Install-InfrastructureHealth.ps1 -File)
    if ($installers.Count -ne 1) { throw 'Expected one health installer.' }
    $packageRoot = $installers[0].DirectoryName
    if ((Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'VERSION')).Trim() -cne $release.Tag.Substring(1)) { throw 'Package VERSION differs from the locked release.' }
    Import-Module WebAdministration
    # Do not adopt an existing unmarked IIS site; it may belong to another app.
    $marker = Join-Path $CL.App.SitePath '.cloudlab-health-owner'
    if (Test-Path "IIS:\Sites\$($CL.App.SiteName)") {
        if (-not (Test-Path -LiteralPath $marker) -or (Get-Content -Raw -LiteralPath $marker).Trim() -ne $CL.ProjectId) { throw 'Refusing to adopt an existing IIS site.' }
        if ((Get-Website -Name $CL.App.SiteName).PhysicalPath -ne $CL.App.SitePath) { throw 'Existing site path mismatch.' }
    } else {
        if (Test-Path "IIS:\AppPools\$($CL.App.AppPoolName)") { throw 'Refusing to adopt an existing app pool.' }
        New-WebAppPool -Name $CL.App.AppPoolName | Out-Null
        Set-ItemProperty "IIS:\AppPools\$($CL.App.AppPoolName)" -Name managedRuntimeVersion -Value ''
        New-Website -Name $CL.App.SiteName -PhysicalPath $CL.App.SitePath -ApplicationPool $CL.App.AppPoolName -IPAddress '127.0.0.1' -Port 8080 | Out-Null
        Set-Content -LiteralPath $marker -Value $CL.ProjectId -Encoding ascii
    }
    $appPath = Join-Path $CL.App.SitePath 'App'
    New-Item -ItemType Directory -Path $appPath -Force | Out-Null
    $app = Get-WebApplication -Site $CL.App.SiteName -Name App
    if ($app -and ($app.PhysicalPath -ne $appPath -or $app.ApplicationPool -ne $CL.App.AppPoolName)) { throw 'Existing /App mapping mismatch.' }
    if (-not $app) { New-WebApplication -Site $CL.App.SiteName -Name App -PhysicalPath $appPath -ApplicationPool $CL.App.AppPoolName | Out-Null }
    $vdir = Get-WebVirtualDirectory -Site $CL.App.SiteName -Application App -Name images
    if ($vdir -and $vdir.PhysicalPath -ne $CL.App.ImagePath) { throw 'Existing images mapping mismatch.' }
    if (-not $vdir) { New-WebVirtualDirectory -Site $CL.App.SiteName -Application App -Name images -PhysicalPath $CL.App.ImagePath | Out-Null }
    foreach ($path in @($CL.App.SitePath,$CL.App.ImagePath)) {
        & icacls.exe $path /grant "IIS AppPool\$($CL.App.AppPoolName):(OI)(CI)(RX)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot grant IIS read access.' }
    }
    & $installers[0].FullName -SiteName $CL.App.SiteName -ApplicationPath '/App' -ImagesVirtualDirectory images -ApplicationPhysicalPath $appPath -ImagesPhysicalPath $CL.App.ImagePath
    $health = Join-Path $appPath 'health'
    if (-not (Test-Path -LiteralPath (Join-Path $health 'vendor/openseadragon/6.1.0/openseadragon.min.js'))) { throw 'OpenSeadragon runtime missing; health installation is incomplete.' }
    if (-not (Get-ScheduledTask -TaskName 'Infrastructure Health & Benchmark Diagnostics' -ErrorAction Stop)) { throw 'Health diagnostics task missing.' }
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8080/App/health/'
    if ($response.StatusCode -ne 200) { throw 'Local health dashboard HTTP check failed.' }
    $release | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $packageDir 'installed-release.json') -Encoding utf8
} finally { if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force } }
