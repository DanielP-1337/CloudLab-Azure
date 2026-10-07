#!/usr/bin/env bash
set -euo pipefail
systemctl is-active --quiet keycloak nginx oauth2-proxy postgresql
curl --fail --silent http://127.0.0.1:9000/health/ready >/dev/null
curl --fail --silent http://127.0.0.1:4180/ready >/dev/null
openssl x509 -in /etc/nginx/cloudlab/chain.pem -noout -checkend 2592000 >/dev/null
python3 - <<'PYTHON'
import shutil,json,urllib.request
from pathlib import Path
c=json.loads(Path("/etc/cloudlab/config.json").read_text())
with urllib.request.urlopen("https://"+c["BackendHost"]+c["App"]["HealthPath"],timeout=30) as response:
 if response.status != 200: raise RuntimeError("IIS HTTPS probe failed")
for path in ['/','/var/lib/postgresql']:
 if shutil.disk_usage(path).free < 5*1024**3: raise RuntimeError('Less than 5 GiB free: '+path)
PYTHON
