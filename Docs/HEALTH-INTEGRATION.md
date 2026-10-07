# Infrastructure Health & Benchmark integration

This opt-in provider installs the generic health dashboard instead of a custom
application wrapper. It creates a dedicated IIS site, `/App`, and an `images`
virtual directory pointing to `App.ImagePath`. It preserves the configured HDD
image disk (512 GiB for the 500 GB planning requirement) and disk type settings.
It does not fill that disk with 500 GB of synthetic data.

## Prepare locally (no Azure resources or installation)

Run from the CloudLab-Azure repository in PowerShell 7:

```powershell
.\Scripts\Prepare-HealthRelease.ps1
```

The first call resolves the latest published non-prerelease, validates the
release asset URL and SHA256SUMS against GitHub's asset digest, downloads the ZIP,
and verifies its size and SHA-256. The ZIP and `health-release.json` remain under
ignored `.local/releases`. This trusts the selected GitHub repository and its
release publisher; a matching hash is not a code signature or a security review.
Never store tokens or credentials in this lock.

Subsequent calls reuse the lock without resolving latest again. To intentionally
update the selection use `-Refresh`, or select `-Version v0.1.8 -Refresh`.
Do not refresh while a deployment is running. Release updates require review:
the adapter was written for the 0.1.8 installer contract.

Edit **only** `.local/config/lab.psd1`. Inside its existing `App` hashtable, add or
replace these entries (do not paste assignments into the PowerShell terminal):

```powershell
Provider = 'InfrastructureHealth'
HealthPath = '/App/health/'
WriterServices = @()
```

Keep `SiteName`, `AppPoolName`, `SitePath`, `ImagePath`, drive and disk settings.
`InstallerPath` and `InstallerSha256` are unused in this mode and may stay as-is.
Do not set `QuiesceReviewed` automatically: review the export paths and lifecycle
before enabling exports. The adapter disables/stops the diagnostic scheduled
task during application quiescence and restores its previous enabled state on
resume. Other configured services and the IIS pool retain their existing flow.

## Deployment (cost warning)

**Azure deployment and running VMs, disks, storage, networking, and gateways can
incur charges.** This integration does not deploy infrastructure automatically.
After the existing infrastructure, egress, certificates and identity prerequisites
are complete, the existing `Deploy-Lab.ps1 -Stage Application` uses this provider.
It still requires `-EnableBillableResources`. No deploy command is run by the
preparation script or offline tests.

The Application stage reads the lock before invoking the VM. The VM downloads
that exact release URL again, verifies the size/hash before executing code,
rejects unsafe ZIP paths, and checks the package VERSION. A missing or changed
asset fails closed; it never falls back to latest. The local cached ZIP is not
uploaded to Azure. Preserve the local lock for reproducible reruns.

The installer runs under 64-bit Windows PowerShell 5.1 / LocalSystem. It retains
the upstream pinned OpenSeadragon download and hash verification. GitHub outbound
HTTPS is required. Missing OpenSeadragon is treated as incomplete installation.
The adapter checks the dashboard through a loopback-only HTTP binding on port
8080. The existing CloudLab TLS binding and Keycloak path remain in place.
Existing unmarked sites and pools are not adopted. No `-Force` is passed to the
health installer. A failed installation can leave partial changes on the VM;
inspect them before retrying.

## What these checks do not establish

- HTTP success and a scheduled task do not establish SQL authentication or MFA.
- The generic dashboard's default HealthCheck DSN still requires an ODBC driver,
  DSN, SQL permissions and suitable authentication. A standalone VM's SYSTEM
  identity is not automatically a remote SQL login. No SQL password is embedded.
- The SQL installation media/hash/collation and Keycloak/TLS/DNS placeholders
  remain separate prerequisites. This change does not make Stage All ready.
- Real reference images are optional, local data; do not put them in GitHub.
- Export paths remain explicit and capped by the existing MaxArchiveMB setting.
  This is not a backup solution for the whole 500 GB image collection.
- No Azure, IIS, scheduled-task, ODBC, or browser MFA runtime test was performed
  while building this patch. Run the local tests before deployment.

Use `Provider = 'Custom'` (or omit Provider) to retain the original reviewed
installer-wrapper workflow.
