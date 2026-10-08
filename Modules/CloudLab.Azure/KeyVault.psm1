$ErrorActionPreference = 'Stop'
function Initialize-CLVault {
    param($Config)
    $v = Get-AzKeyVault -VaultName $Config.VaultName -ResourceGroupName $Config.SharedResourceGroup -ErrorAction SilentlyContinue
    if (-not $v) {
        # Az.KeyVault 6+ defaults to RBAC and removed -EnableRbacAuthorization.
        # Older versions require the explicit switch. Never fall back to access policies.
        $parameters = @{
            VaultName = $Config.VaultName
            ResourceGroupName = $Config.SharedResourceGroup
            Location = $Config.Location
            Sku = 'Standard'
            EnablePurgeProtection = $true
            SoftDeleteRetentionInDays = 90
            ErrorAction = 'Stop'
        }
        $command = Get-Command New-AzKeyVault -ErrorAction Stop
        if ($command.Parameters.ContainsKey('EnableRbacAuthorization')) {
            $parameters.EnableRbacAuthorization = $true
        } elseif (-not $command.Parameters.ContainsKey('DisableRbacAuthorization')) {
            throw 'Unsupported Az.KeyVault command: cannot confirm RBAC default behavior.'
        }
        $v = New-AzKeyVault @parameters
    }
    if (-not $v.EnableRbacAuthorization) { throw 'Use an RBAC vault; do not convert a shared legacy vault automatically.' }
    # The TLS endpoint is public with RBAC. See README for the private-endpoint variant.
    return $v
}
function Grant-CLSecretRead {
    param([string]$VaultId,[string]$PrincipalId,[string[]]$Secrets)
    foreach ($secret in $Secrets) {
        $scope = "$VaultId/secrets/$secret"
        if (-not (Get-AzRoleAssignment -ObjectId $PrincipalId -Scope $scope -RoleDefinitionName 'Key Vault Secrets User' -ErrorAction SilentlyContinue)) {
            New-AzRoleAssignment -ObjectId $PrincipalId -Scope $scope -RoleDefinitionName 'Key Vault Secrets User' | Out-Null
        }
    }
}
Export-ModuleMember -Function *-CL*
