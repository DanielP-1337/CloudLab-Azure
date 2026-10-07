# Synthetic health export and recovery

This opt-in smoke test supports only the isolated `CloudLabHealth` database on
SQL Server 2022 Developer, the default instance, and the generic health app.
It is not an adapter for an employer application or real patient records.

## Prepare locally (no Azure charges)

Run the offline tests, then:

```powershell
.\Scripts\Initialize-HealthRecovery.ps1 -WhatIf
.\Scripts\Initialize-HealthRecovery.ps1
```

The helper backs up and edits only `.local/config/lab.psd1`. It selects
`Export.SqlMode = 'HealthNative'`, clears unused wrapper fields, and sets
`App.QuiesceReviewed = $true` for this specific profile. It refuses a configured
custom SQL wrapper. Review the writer boundary: the dedicated health IIS site,
app pool, diagnostics task, no additional writer services, stopped SQL Agent,
and no active SQL user transactions. External clients/writers are not blocked
by this test and must not be connected. A running SQL engine is required.

The public example remains `Custom`. Recovery Services remains disabled and
its placeholder settings remain unused. Do not fill them merely to pass a
placeholder search. Do not put passwords or certificates in public config.

## Column encryption and retained credentials

The first native backup prepares one generic synthetic encrypted value using a
new database master key (DMK), a database certificate, and an AES-128 symmetric
key. The DMK protects the certificate private key; the certificate protects the
symmetric key. This hierarchy is separate from the SQL transport TLS certificate.
No existing encryption keys are dropped, replaced, or regenerated. Conflicting
unmarked encryption objects cause a failure requiring review.

`Import-HealthSqlSecrets.ps1` now creates/reuses a separate randomly generated
`health-sql-dmk-password` secret. `Configure-HealthSql.ps1` grants only the SQL VM
access to it; the app VM keeps its restricted SQL-login secret access. The
existing SQL-login permissions are not expanded to decrypt the test value.

The database records the exact master-key secret version at first creation.
Every backup manifest records that version. Reuse and restore retrieve that
version, not an unrelated later password. Keep that secret version enabled and
recoverable for as long as its backups are needed. The runbooks do not rotate
it. Updating a Key Vault password alone does not change a SQL master key.

A database backup contains this database's encrypted key hierarchy. Restore
opens the DMK with the retained password and, where needed, adds protection by
the destination instance's service master key (SMK). It does not restore or
replace the destination instance's SMK. The encrypted value must decrypt to its
known synthetic plaintext before success is reported. Missing/incorrect secrets
cause failure; there is no plaintext fallback.

This proves this lab's hierarchy, not recovery of arbitrary existing encrypted
applications. Those require their original keys, passwords, login mappings and
vendor-reviewed procedures. Microsoft also recommends separate protected,
off-site master-key backups. Such privileged key escrow is outside this lab's
ordinary export allowlist. Never run drop-and-recreate key scripts against data
you intend to recover.

## Later Azure execution (billable; do not run during local preparation)

**Cost notice:** creating/running VMs, Key Vault operations, retained blobs,
backup/restore runtime, downloads and network transfer can incur Azure charges.
A successful workload teardown retains Key Vault and export storage, which can
continue to cost money. There is no automatic spending cap or teardown timer.

After the retained resources and VMs have been deployed, SQL and the health app
installed, and the TLS prerequisites completed, import secrets and configure the
SQL connection using the existing health-SQL workflow:

```powershell
.\Runbooks\Import-HealthSqlSecrets.ps1 -EnableBillableResources
.\Runbooks\Configure-HealthSql.ps1 -ConfigPath .\.local\config\lab.psd1 -Interactive -EnableBillableResources
```

Run application/TLS/SQL acceptance tests before export. The following commands
are also billable and are shown for the later deployed lab:

```powershell
.\Runbooks\Export-Lab.ps1 -ConfigPath .\.local\config\lab.psd1 -Interactive -EnableBillableResources
.\Runbooks\Get-LabExports.ps1 -ConfigPath .\.local\config\lab.psd1 -Interactive
```

Native export pauses the reviewed writers and produces a unique full
`COPY_ONLY, CHECKSUM, COMPRESSION` SQL backup. It performs VERIFYONLY, an actual
restore to a random temporary database with new data/log files, CHECKDB,
reference-row validation, and decryption verification before uploading Sql.zip.
The temporary proof database is dropped after validation. A failed proof does
not produce a completed export receipt. Files are bounded to the configured
archive budget (maximum 512 MiB); restored database files must total at most
8 GiB and leave a 2-GiB free-space margin.

The export receipt is saved under
`.local/results/<deployment-id>/<export-run-id>/export-receipt.json`.
Keep this receipt and the downloaded private artifacts. Hashes establish
consistency against your trusted receipt, not independent publisher authenticity.
Writers remain stopped after success until explicit `Resume-Lab` or teardown.
Native mode rejects metadata-only export and requires a SQL archive before the
existing destroy guard can pass. Review the receipt and downloads before using
the existing `Destroy-Lab.ps1` workflow; it still enforces ownership and inventory.

## Explicit restore test (billable)

Use the same project identity, retained vault, storage account and container.
The target SQL VM must already have SQL installed, its data directories created,
and health-SQL configuration/scoped secret permissions applied. This can be the
current lab or a newly deployed lab after teardown. Testing on a fresh VM is
required to demonstrate recovery independently of the original instance.

Assign `$receipt` to the actual trusted receipt file under `.local`, then:

```powershell
.\Runbooks\Restore-HealthSql.ps1 -ConfigPath .\.local\config\lab.psd1 -ReceiptPath $receipt -WhatIf
# COST NOTICE: the next command downloads Azure data and uses the running SQL VM.
.\Runbooks\Restore-HealthSql.ps1 -ConfigPath .\.local\config\lab.psd1 -ReceiptPath $receipt -Interactive -EnableBillableResources
```

The restore verifies archive length/hash and an exact archive-entry allowlist,
manifest ownership, inner backup hash and SQL backup metadata. It restores to
`CloudLabRestore_<random>` with new files, never `WITH REPLACE`, and repeats
CHECKDB, reference-row and decryption checks. Success keeps that separate
restricted-user database for inspection; it does not switch the app to it or
remap its users. Failure attempts to remove only this invocation's new database.
The controller saves a private restore report under
`.local/results/<deployment-id>/restores/`. Downloaded guest artifacts remain on
the disposable SQL disk. Repeated successful restores consume disk space.

A restore invalidates any current completed export for teardown purposes.
If writers are still in maintenance, explicitly resume before a new export.
Then export again before teardown; the workload disk deletion also removes
validation databases. The old trusted receipt remains usable as restore input.

## Boundaries and validation

Only the synthetic database and selected log paths are exported. The 512-GiB
image disk and the identity-provider database are not backed up by this profile.
VMs/software/secrets are rebuilt or reprovisioned; this is not full application
or identity-state disaster recovery. Separate protected export of image and
identity data needs its own capacity and restore plan.

Offline tests exercise profile/receipt rejection, ZIP traversal/duplicate
protection, config migration and guest-payload parsing. Actual SQL backup,
Key Vault propagation, cross-instance key opening and decryption require the
later Windows/Azure integration run. Do not treat offline success as proof that
a real backup is recoverable.

References:
- [CREATE MASTER KEY](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-master-key-transact-sql?view=sql-server-ver16)
- [ALTER MASTER KEY](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-master-key-transact-sql?view=sql-server-ver16)
- [RESTORE VERIFYONLY](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver16)
