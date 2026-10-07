$ErrorActionPreference = 'Stop'
function Deploy-CLKeycloak {
    param($Config,[string]$ProjectRoot)
    foreach ($key in 'Version','ProxyVersion') { Assert-CLValue $Config.Keycloak[$key] "Keycloak.$key" '^\d+\.\d+\.\d+$' }
    foreach ($key in 'Sha256','ProxySha256') { Assert-CLValue $Config.Keycloak[$key] "Keycloak.$key" '^[a-fA-F0-9]{64}$' }
    foreach ($key in 'AppHost','AuthHost','BackendHost') { Assert-CLValue $Config[$key] $key '^[a-zA-Z0-9.-]+$' }
    foreach ($key in 'Realm','ClientId','AllowedRole') { Assert-CLValue $Config.Keycloak[$key] "Keycloak.$key" '^[a-zA-Z0-9_-]+$' }
    $payload = Get-CLGuestPayload $Config "$ProjectRoot/Scripts/Linux/Install-Keycloak.sh" Linux
    Invoke-CLGuest $Config $Config.Keycloak.Name $payload Linux
}
Export-ModuleMember -Function *-CL*
