@{
    # Copy with Scripts/Initialize-Local.ps1. Never edit this public template.
    SubscriptionId = 'REPLACE-subscription-guid'
    TenantId = 'REPLACE-tenant-guid'
    ProjectId = 'REPLACE-local-project-guid'
    Environment = 'sandbox'
    ResourceGroup = 'REPLACE-test-resource-group'
    SharedResourceGroup = 'REPLACE-retained-resource-group'
    Location = 'australiaeast'
    Prefix = 'lab'
    VNetName = 'lab-vnet'
    AddressSpace = '10.40.0.0/16'
    Subnets = @{
        AppGatewaySubnet = '10.40.1.0/24'
        AppSubnet = '10.40.2.0/24'
        DbSubnet = '10.40.3.0/24'
        KeycloakSubnet = '10.40.4.0/24'
    }
    VaultName = 'REPLACE-unique-vault-name'
    # Required only for noninteractive managed-identity execution.
    AutomationPrincipalId = ''
    AdminUser = 'labadmin'
    SshPublicKey = 'REPLACE-public-key'
    WindowsPasswordSecret = 'windows-admin-password'
    CertificateSecret = 'web-tls'
    GatewayCertificateSecretUri = 'https://REPLACE.vault.azure.net/secrets/web-tls'
    AppHost = 'REPLACE-app.example.com'
    AuthHost = 'REPLACE-login.example.com'
    BackendHost = 'REPLACE-backend.example.com'
    GatewayCapacity = 2
    Keycloak = @{
        Name = 'lab-auth'; Size = 'Standard_D2s_v5'; Ip = '10.40.4.10'
        Publisher = 'Canonical'; Offer = 'ubuntu-24_04-lts'; Sku = 'server'; ImageVersion = 'latest'
        Version = '26.8.0'; Sha256 = 'REPLACE-approved-sha256'
        ProxyVersion = '7.15.5'; ProxySha256 = 'REPLACE-approved-sha256'
        Realm = 'lab'; ClientId = 'lab-proxy'; AllowedRole = 'lab-user'
        DbPasswordSecret = 'identity-db-password'
        BootstrapPasswordSecret = 'identity-bootstrap-password'
        ClientSecret = 'identity-client-secret'; CookieSecret = 'proxy-cookie-secret'
    }
    App = @{
        Name = 'lab-app'; Size = 'Standard_D4s_v5'; Ip = '10.40.2.10'
        Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = '2025-datacenter-g2'
        ImageVersion = 'latest'; DiskGB = 128; DriveLetter = 'F'
        InstallerPath = 'C:\LabSetup\Install-Application.ps1'
        InstallerSha256 = 'REPLACE-reviewed-sha256'
        SiteName = 'LabApp'; AppPoolName = 'LabApp'; SitePath = 'C:\inetpub\LabApp'
        ImagePath = 'F:\AppData'; HealthPath = '/'
        WriterServices = @('REPLACE-actual-services')
        QuiesceReviewed = $false
    }
    Sql = @{
        Name = 'lab-sql'; Size = 'Standard_D4s_v5'; Ip = '10.40.3.10'
        Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = '2025-datacenter-g2'
        ImageVersion = 'latest'; DiskGB = 128; DriveLetter = 'F'
        SetupPath = 'C:\LabSetup\Sql\setup.exe'; SetupSha256 = 'REPLACE-approved-sha256'
        Instance = 'MSSQLSERVER'; MajorVersion = 16; Port = 1433
        Collation = 'REPLACE-approved-collation'; Databases = @('REPLACE-database')
        MaxMemoryMB = 8192
    }
    Backup = @{
        Enabled = $false # Recovery Services is deliberately outside the disposable lifecycle.
        VaultName = 'REPLACE-vault'; PolicyName = 'LabEnhancedDaily'
        RetentionDays = 30; MaximumAgeHours = 30; SqlPath = 'F:\LabBackup'
        RestoreStorageAccount = 'REPLACE-account'; RestoreResourceGroup = 'REPLACE-restore-rg'
    }
    Export = @{
        StorageAccount = 'REPLACE-unique-storage-account'
        Container = 'lab-exports'
        # Explicit bounded allowlist. Never include secrets/certificates or an entire drive.
        AppPaths = @('C:\inetpub\logs\LogFiles')
        SqlPaths = @('F:\LabBackup\Export')
        KeycloakPaths = @('/var/log/nginx')
        MaxArchiveMB = 512
        # Optional LOCAL wrapper on the SQL VM creates/VERIFYONLY-checks native .bak files.
        # Do not copy live .mdf/.ldf. Empty means no native DB export was requested.
        SqlPreparePath = ''
        SqlPrepareSha256 = ''
    }
}
