# Download official pinned assets locally and report their SHA256 values for review.
# Cross-check signatures/digests on release pages before approving the configuration.
[CmdletBinding()]
param([string]$KeycloakVersion='26.8.0',[string]$ProxyVersion='7.15.5',[Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
foreach ($v in @($KeycloakVersion,$ProxyVersion)) { if ($v -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected numeric version.' } }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$urls=@(
 "https://github.com/keycloak/keycloak/releases/download/$KeycloakVersion/keycloak-$KeycloakVersion.tar.gz",
 "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v$ProxyVersion/oauth2-proxy-v$ProxyVersion.linux-amd64.tar.gz"
)
foreach ($url in $urls) {
    $path=Join-Path $Destination ([IO.Path]::GetFileName($url))
    Invoke-WebRequest -Uri $url -OutFile $path
    Get-FileHash -Algorithm SHA256 -LiteralPath $path
}
