# Health application SQL adapter

This opt-in CloudLab adapter connects Infrastructure Health & Benchmark **0.1.8**
to the SQL Server **2022 default instance** on the dedicated Windows Server 2025
VM. It is a sandbox feature using synthetic data, not a production database
migration. The original health release archive remains unchanged.

## Local preparation: no Azure charges

From Windows PowerShell 7.4 or later in the project directory:

```powershell
.\Scripts\Initialize-HealthSql.ps1 -WhatIf
.\Scripts\Initialize-HealthSql.ps1
.\Tests\Test-Project.ps1
.\Tests\Test-HealthSql.ps1
py -3.11 .\Scripts\check_public.py --require-private-terms
```

Choose a separate SQL PFX password of at least 16 characters. Keep it for the
later import; do not paste it into chat, command-line arguments or Git. This
helper briefly creates certificates in the current user's Personal store,
exports the encrypted SQL leaf PFX, and deletes the temporary certificates and
private key containers. It does not add a trusted root to the local computer.
The root private key is not retained. SQL uses a separate root because the
previous web root's private key was deliberately discarded.

Files remain in `.local/pki/sql-health`, `.local/media/health-odbc` and
`.local/releases/health-odbc.json`. The helper downloads and Authenticode-checks
the Microsoft x64 ODBC 18.7.1.1 MSI without installing it, then pins its SHA-256.
That package supplies both 64-bit and 32-bit drivers and does not require a
separate Visual C++ runtime prerequisite. First-use trust is based on the
Microsoft download channel and valid Microsoft signature, not an independent
published checksum. Later downloads must match the local lock.

The helper backs up and updates only the private `lab.psd1`: it enables
`HealthSql` and sets `Sql.Databases = @('CloudLabHealth')`. Preserve this isolated
profile; do not use it with real databases. A repeat validates and reuses the
PKI and driver lock. Partial PKI is rejected rather than silently overwritten.
The SQL leaf expires after 90 days. Rotation requires explicit preparation and
review; existing vault certificates are never silently replaced.

## Azure operations: billable, run only at the appropriate deployment stage

The commands below are documented for later use. They require existing Azure
resources; they do not create VMs. Key Vault operations/storage and VM runtime
are billable. Configure-HealthSql restarts SQL Server and pauses the diagnostics
task. Do not run it against a production environment.

1. Create the retained lab Key Vault through the normal bootstrap process.
2. Sign in to the configured subscription. With certificate/secret write rights,
   import the SQL PFX and create the generated password:

```powershell
.\Runbooks\Import-HealthSqlSecrets.ps1 -WhatIf
.\Runbooks\Import-HealthSqlSecrets.ps1 -EnableBillableResources
```

The password is cryptographically random and stored only in Key Vault as
`health-sql-password`; no local plaintext password file is written. Certificate
`sql-health-tls` contains only the SQL leaf private key. Both objects carry the
project tag. Existing objects with conflicting ownership are rejected. This
runbook reuses existing secrets; it does not rotate credentials automatically.
Key Vault permission propagation can require a later retry.

3. Complete the normal network, compute, SQL and InfrastructureHealth application
   deployment stages. Retain private networking and the app-to-SQL firewall rule.
4. Configure the adapter:

```powershell
.\Runbooks\Configure-HealthSql.ps1 `
    -ConfigPath .\.local\config\lab.psd1 `
    -Interactive -EnableBillableResources
```

The existing lifecycle lock, resource-group ownership checks and maintenance
checks apply. Prior exports are invalidated before changes. The runbook grants
only secret-scoped read access: SQL VM to its TLS secret and the login password;
app VM to the login password only. Client VMs do not receive the SQL private key.
Managed identity is available to software running on the VM, so the VM itself
is the credential-access boundary. It is not isolation between local processes.

## SQL and TLS behavior

- Separate synthetic database `CloudLabHealth`, tagged with the project identity.
- Login `cloudlab_health`, mapped user, CONNECT and EXECUTE on `dbo.ReadHealth`.
  No sysadmin, db_owner, broad db_datareader or db_datawriter membership is added.
- A synthetic table contains a single test row. The procedure returns the SQL
  server name, current database and configured image directory. It does not read
  real patient records or image content. Table writes are explicitly denied.
- Mixed mode is enabled for this dedicated instance; `sa` is not enabled or used.
- The SQL certificate has Server Authentication EKU and a legacy RSA CSP key with
  KeySpec AT_KEYEXCHANGE. The SQL service gets read access to that private key.
- SQL forces encryption. Both DSNs and the adapter require `Encrypt=Yes` and
  `TrustServerCertificate=No`. The client connects to the private IP and checks
  the expected SAN using `HostnameInCertificate=sql.cloudlab.test`. No DNS or
  hosts-file changes are required for this SQL alias.
- The app VM trusts only the public SQL root added by this adapter. The probe
  obtains its password from Key Vault via managed identity at each invocation;
  DSNs and its settings contain no password. This generates recurring Key Vault
  reads for the 32-bit and 64-bit scheduled probes.

The runtime adapter replaces only the installed ODBC helper for reviewed release
0.1.8. It verifies the original normalized helper hash (or its own unchanged
adapter) before replacement, checks site ownership and LocalSystem task identity,
and restricts the Engine directory to Administrators and SYSTEM. Unexpected
helper changes, conflicting DSNs or database/login ownership cause a failure.
Reapply after an application deployment because the application installer can
restore its original Windows-authentication helper. Other health releases need
a reviewed adapter update. The public health-app repository is not modified.

After configuration, both bitnesses must pass a real query and permission checks.
A second connection must fail specifically for an incorrect TLS hostname.
Unrelated connection failures do not count as a successful negative test.
On failure the diagnostics task remains disabled; its previous enabled state is
saved for a retry. Partial database/login setup is rejected when ownership cannot
be established; inspect it manually rather than deleting or adopting objects.

`Test-Lab.ps1` additionally checks the real SQL probe when HealthSql is enabled.
This does not replace the separate interactive MFA and application acceptance
checks, load testing, SQL cumulative-update review or backup/restore tests.

## Teardown and retained material

The database, DSNs, machine trust roots, private SQL key and runtime adapter live
on disposable VM disks. Normal lab teardown removes them with those disks.
The retained Key Vault certificate/password and local PKI survive teardown;
retained vault operations/storage may still cost money. Neither private PKI nor
SQL installation media belongs in the public repository.

## Validation boundaries

Offline tests cover configuration migration/idempotence, profile rejection,
project-bound certificate chain validation and composed PowerShell parsing.
The authoring environment has no Windows/PowerShell runtime: these tests must be
run locally. SQL DDL, CSP key import, ODBC MSI installation and positive/negative
connections additionally require the later Windows VM smoke test.

Sources:
- https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/certificate-requirements
- https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-sql-server-encryption
- https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server
- https://learn.microsoft.com/en-us/sql/connect/odbc/dsn-connection-string-attribute
