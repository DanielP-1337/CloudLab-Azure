# SQL Server 2022 Developer media

This opt-in provider installs SQL Server 2022 Developer on the existing Windows
Server 2025 VM. It does not select a SQL Marketplace image. Developer is for
non-production development/testing only. Azure Windows VM runtime, disks and
network resources still incur charges, including during installation.

## Prepare locally (no Azure operations)

Run on Windows with PowerShell 7.4 or later, with several GB of free disk space:

```powershell
.\Scripts\Prepare-SqlDeveloperMedia.ps1 -WhatIf
.\Scripts\Prepare-SqlDeveloperMedia.ps1
```

The Microsoft Developer bootstrapper runs in Download-only mode. It may request
elevation. ISO mounting can require an elevated terminal. It does not install SQL
Server on the workstation. The download can take several minutes.

The helper checks the downloader's Microsoft Authenticode signature before
execution, downloads the English ISO, checks the signed SQL 2022 setup, and
records downloader, entire ISO, and setup SHA-256 hashes in
`.local/releases/sql-developer.json`. This is first-use trust in Microsoft's
signed downloader and its download channel, not an independent published ISO
checksum. Inspect the downloaded media before deployment. Keep all media and
lock files local; do not commit or redistribute them in the public repository.

In `.local/config/lab.psd1`, add inside the existing `Sql` hashtable:

```powershell
MediaProvider = 'Developer2022'
```

Replace the existing Collation value with:

```powershell
Collation = 'SQL_Latin1_General_CP1_CI_AS'
```

Do not add duplicate keys. Keep MajorVersion = 16, MaxMemoryMB = 4096 and the
existing Windows Server 2025 image. SetupPath/SetupSha256 are ignored by this
provider; the private media lock supplies the verified mounted setup instead.
Without MediaProvider, or with Staged, the previous staged-media path still works.

## Later deployment (billable Azure environment)

The existing SQL deployment phase embeds the approved lock into its guest
payload. The VM downloads through the same signed Microsoft bootstrapper and
rejects changes to the bootstrapper, complete ISO, or mounted setup before
executing SQL setup. It mounts the verified ISO read-only, invokes the existing
unattended installer, and dismounts in a finally block. Media stays cached on the
OS disk for retries and disappears with that disk during normal lab teardown.
Allow sufficient free OS-disk space and outbound HTTPS for Microsoft's download
and certificate-validation services. Downloads are synchronous and may exceed
Azure Run Command time limits on slow connections; inspect the guest before
retrying and do not run concurrent SQL deployments.

The installed edition must be Developer (EditionID -2117995310), major version
16. Existing instances of another edition are rejected, never converted. SQL
setup exit code 3010 requires a VM reboot followed by a deployment retry.

This provider preserves the current Windows-authentication setup, private static
TCP port, app-IP firewall restriction, data directories and configured memory
limit. It does not import a company INI, configure mixed mode, create application
logins/databases, install an ODBC driver, or configure the health app's DSN.
Those remain separate prerequisites for an end-to-end SQL health test. It also
does not apply cumulative updates; review and stage an appropriate supported SQL
2022 update before treating the resulting installation as deployment-ready.

An existing lock is reused without refreshing it. If Microsoft changes or removes
the download, deployment fails closed. Do not bypass the hash checks. Archive
both `.local/releases/sql-developer.json` and `.local/media/sql2022-developer`
outside those paths before preparing and reviewing a new lock.

## Validation

`Tests/Test-SqlDeveloperMedia.ps1` exercises lock rejection and checksum guards
with mocked downloads; no Microsoft download, SQL install, or Azure call occurs.
Actual downloader behavior, mounting, Windows signatures and installation must
also be verified on Windows. Preparation is not a complete VM deployment test.

Sources:
- https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2022
- https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql
- https://aws.amazon.com/blogs/database/create-a-sql-server-developer-edition-instance-on-amazon-rds-for-sql-server/
