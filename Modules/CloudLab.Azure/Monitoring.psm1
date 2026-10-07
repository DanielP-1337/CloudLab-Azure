$ErrorActionPreference = 'Stop'
function Test-CLHealth {
    param($Config,[string]$ProjectRoot)
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($role in 'App','Sql','Keycloak') {
        try {
            $vm = Get-AzVM -Name $Config[$role].Name -ResourceGroupName $Config.ResourceGroup -Status
            if ('PowerState/running' -notin $vm.Statuses.Code) { throw 'VM is not running.' }
            switch ($role) {
                App { Invoke-CLWindowsScript $Config $ProjectRoot 'Test-Application.ps1' $Config.App.Name }
                Sql { Invoke-CLWindowsScript $Config $ProjectRoot 'Test-Sql.ps1' $Config.Sql.Name }
                Keycloak { Invoke-CLGuest $Config $Config.Keycloak.Name (Get-Content -Raw "$ProjectRoot/Scripts/Linux/Test-Keycloak.sh") Linux }
            }
        } catch { $errors.Add("${role}: $($_.Exception.Message)") }
    }
    try {
        $discovery = Invoke-RestMethod -Uri "https://$($Config.AuthHost)/realms/$($Config.Keycloak.Realm)/.well-known/openid-configuration" -TimeoutSec 30
        if ($discovery.issuer -ne "https://$($Config.AuthHost)/realms/$($Config.Keycloak.Realm)") { throw 'OIDC issuer mismatch.' }
        # Verify the unauthenticated browser request does NOT reach the application.
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        try {
            $response = $client.GetAsync("https://$($Config.AppHost)/").GetAwaiter().GetResult()
            if ([int]$response.StatusCode -notin @(302,303)) { throw 'Expected authentication redirect.' }
            $location = [string]$response.Headers.Location
            $response.Dispose()
        } finally { $client.Dispose(); $handler.Dispose() }
        if ($location -notmatch '^/oauth2/' -and $location -notlike "https://$($Config.AuthHost)/*" -and $location -notlike "https://$($Config.AppHost)/oauth2/*") { throw 'Unexpected authentication redirect target.' }
    } catch { $errors.Add("Ingress: $($_.Exception.Message)") }
    if ($errors.Count) { throw ($errors -join "`n") }
    Write-Output 'Automated health checks passed. Interactive MFA and authenticated application checks require a separate local test hook.'
}
Export-ModuleMember -Function *-CL*
