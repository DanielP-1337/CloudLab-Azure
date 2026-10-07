# Local .test names and lab TLS

This opt-in smoke-test profile needs no purchased domain or public DNS zone.
It uses `app.cloudlab.test`, `auth.cloudlab.test`, and `backend.cloudlab.test`.
These names are not publicly resolvable. It is for your private lab, not a
publicly trusted or production PKI.

## 1. Prepare locally (no Azure charges)

Use PowerShell 7.4 or later on your Windows test PC, from the repository root:

```powershell
.\Scripts\Initialize-LabTls.ps1 -WhatIf
.\Scripts\Initialize-LabTls.ps1
```

The real run prompts for a PFX password (at least 16 characters). Keep that
password in your password manager for the later Key Vault import. It is never
written to configuration, Git, command arguments, or console output.

The script restricts `.local/pki/lab` to your Windows user and LocalSystem,
creates a self-signed RSA-3072/SHA-256 Root CA (one year), and signs a server
certificate (90 days) containing all three names as SANs. The shared server
certificate preserves the current lab's single-certificate architecture.
The root CA's private key exists only in memory during issuance and is then
disposed; it is not retained, exported, or uploaded. This deliberately prevents
later issuance without generating a new root and explicitly updating trust.

Local files: public `root-ca.cer`, `root-ca.pem`, `server.cer`, an encrypted
`server.pfx` containing the server private key and public root, and a manifest.
Everything stays under ignored `.local`. No certificate-store or hosts changes
are made by preparation. Do not commit any of these files.

The local config gains `LabTlsEnabled = $true`, the three hostnames, and the
versionless backing-secret URI derived from your VaultName/CertificateSecret.
Changed config is backed up locally. Subscription, VM sizes, HDD image storage,
SQL, and health-provider settings are preserved. Reruns validate and reuse the
existing certificates. Existing or partial PKI is never silently overwritten.
The helper refuses to migrate a lab that already has lifecycle state.

## 2. Later: import into the retained Key Vault (Azure costs)

**COST NOTICE:** Key Vault operations/storage and the preceding Bootstrap stage
can incur Azure charges. Do not run deployment stages as part of local setup.
After Bootstrap has created the retained vault, sign in to the configured
subscription. The caller needs certificate-import permissions, such as Key
Vault Certificates Officer; management-plane Owner alone does not grant these
data-plane permissions. This runbook does not assign roles automatically.

```powershell
# Local validation / preview; no Azure request:
.\Runbooks\Import-LabTlsCertificate.ps1 -WhatIf

# Later, after reviewing costs and permissions:
.\Runbooks\Import-LabTlsCertificate.ps1 -EnableBillableResources
```

Supply the PFX password at the secure prompt. The runbook checks the Azure
context, existing vault, local chain, and server key. It imports the PFX as a
Key Vault certificate. Azure supplies the password-free backing PFX secret used
by IIS, nginx, and Application Gateway. The private CA key is never uploaded.
An existing different certificate is not replaced automatically. Reimporting
the same certificate is a no-op.

## 3. Deployment trust and internal resolution

Gateway/Application/Identity deployment validates the local manifest, hostname SANs,
thumbprints, expiry, and chain before loading a public-root-only TLS context.
Therefore the machine running deployment needs `.local/pki/lab` public files;
never put the PFX or password inside guest configuration or Run Command text.

- Application Gateway receives the base64 public DER root and explicitly trusts
  it in both HTTPS backend settings. Public-CA mode remains available with
  `LabTlsEnabled = $false` (or the setting absent).
- The IIS VM trusts the lab root and checks that the retrieved server certificate
  matches the prepared leaf thumbprint before binding it.
- The Linux VM adds the root to its system trust store. OAuth2 Proxy and the
  Python HTTPS probe use this store to validate the IIS backend.
- The Linux hosts file maps the backend name to the app VM's private IP and the
  auth name to loopback. An additional nginx listener on **127.0.0.1:443 only**
  serves OIDC discovery using the same HTTPS issuer name and certificate.
  Gateway traffic still uses port 8443. This avoids depending on an already
  healthy gateway while starting OAuth2 Proxy. Public CA mode does not add this
  loopback listener or auth hosts entry.

No TLS verification bypass is enabled. The lab CA has no CRL/OCSP service;
local manifest validation checks signatures, names, and validity without online
revocation. The Azure/guest runtime must still be tested after deployment.
Export, resume, and destroy do not require a valid local certificate; expired
lab certificates must not block teardown.

## 4. Later: connect your test PC (local changes only)

Once the gateway public IPv4 address exists, open an elevated PowerShell 7
terminal **as the same Windows user** who prepared the certificates. Use the
actual address returned by Azure:

```powershell
.\Scripts\Set-LabClientAccess.ps1 -GatewayIp '<gateway-public-ipv4>' -WhatIf
.\Scripts\Set-LabClientAccess.ps1 -GatewayIp '<gateway-public-ipv4>'
```

This trusts only the generated root certificate in CurrentUser/Root and adds a
project-marked hosts block for the app/auth names. It does not trust private
keys. It refuses conflicting entries outside its block and backs up a changed
hosts file locally. The backend name is internal only and is not mapped on the
client. Every additional tester needs equivalent name resolution and root
trust; sharing only a URL is insufficient. Open the app at
`https://app.cloudlab.test/App/health/`. Existing Keycloak MFA/user/role setup is
still required. Restart the browser after trust/name changes if necessary.

## 5. Local cleanup

```powershell
.\Scripts\Set-LabClientAccess.ps1 -Remove -WhatIf
.\Scripts\Set-LabClientAccess.ps1 -Remove
```

Run as the same user, elevated. This removes only the project-marked hosts block
and root trust that this helper originally added; pre-existing root trust and
unrelated hosts entries are preserved. Keep the local manifest and client state
until cleanup is complete. Cleanup also works after certificate expiry.

`Destroy-Lab.ps1` does not perform this client cleanup or delete the retained
vault/certificate. Retained Azure resources may still cost money. Renewal or
rotation is an explicit later operation: no automatic certificate replacement,
CA trust replacement, or retained-resource deletion is provided.

## Validation and references

Run `Tests/Test-LabTls.ps1` locally. It generates disposable test certificates,
checks the chain and key isolation, tests migration and hosts cleanup, and does
not alter OS trust, real hosts files, or Azure resources. Python tests exercise
the generated nginx/OAuth2 Proxy configurations in both lab/public modes.
Windows trust/ACL changes, Key Vault import, and end-to-end Azure runtime checks
still require execution on the target systems.

- https://www.rfc-editor.org/rfc/rfc2606.html
- https://learn.microsoft.com/azure/application-gateway/certificates-for-backend-authentication
- https://learn.microsoft.com/powershell/module/az.keyvault/import-azkeyvaultcertificate
- https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview/
