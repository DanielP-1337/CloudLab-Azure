#!/usr/bin/env bash
# Executed as root by Azure Run Command. Do not enable shell tracing.
set -euo pipefail
umask 077
exec 9>/var/lock/cloudlab-install.lock
flock -n 9 || { echo 'Another installation is running.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq openjdk-21-jre-headless postgresql nginx curl openssl python3 ca-certificates >/dev/null
install -d -m 700 /etc/cloudlab /var/lib/cloudlab/backup
install -d -m 755 /opt/keycloak/releases /opt/oauth2-proxy /etc/nginx/cloudlab
python3 - <<'PYTHON'
import os,json,urllib.request,time,base64,re,subprocess,pathlib,hashlib,shlex
c=json.loads(base64.b64decode(os.environ['CL_CONFIG_B64']))
k=c['Keycloak']; base=pathlib.Path('/etc/cloudlab')
def write(path,text,mode=0o600):
 p=pathlib.Path(path); p.write_text(text); p.chmod(mode)
write(base/'config.json',json.dumps(c))
lab=c.get('LabTls')
if c.get('LabTlsEnabled') and not lab: raise RuntimeError('Missing lab TLS context')
if lab:
 root_der=base64.b64decode(lab['RootDerBase64'],validate=True)
 if hashlib.sha1(root_der).hexdigest().upper()!=lab['RootThumbprint'].upper(): raise RuntimeError('Lab root fingerprint mismatch')
 (base/'root-ca.der').write_bytes(root_der)
 subprocess.run(['openssl','x509','-inform','DER','-in',str(base/'root-ca.der'),'-out','/usr/local/share/ca-certificates/cloudlab-root.crt'],check=True)
 pathlib.Path('/usr/local/share/ca-certificates/cloudlab-root.crt').chmod(0o644)
 subprocess.run(['update-ca-certificates'],check=True,stdout=subprocess.DEVNULL)
# IMDS token stays only in guest memory. urllib has no proxy for link-local IMDS.
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
req=urllib.request.Request('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net',headers={'Metadata':'true'})
with opener.open(req,timeout=15) as response: token=json.load(response)['access_token']
def secret(name):
 req=urllib.request.Request('https://'+c['VaultName']+'.vault.azure.net/secrets/'+name+'?api-version=7.4',headers={'Authorization':'Bearer '+token})
 for attempt in range(18):
  try:
   with urllib.request.urlopen(req,timeout=20) as response: return json.load(response)['value']
  except urllib.error.HTTPError as e:
   if e.code not in (403,429,500,502,503) or attempt==17: raise RuntimeError('Key Vault secret retrieval failed: '+name) from None
   time.sleep(10)
values={key:secret(k[key]) for key in ['DbPasswordSecret','BootstrapPasswordSecret','ClientSecret','CookieSecret']}
for key in ['DbPasswordSecret','BootstrapPasswordSecret','ClientSecret']:
 if not re.fullmatch(r'[A-Za-z0-9_!@%+=.,:-]{32,128}',values[key]): raise RuntimeError(key+': use 32-128 permitted ASCII characters (see README)')
try:
 if len(base64.urlsafe_b64decode(values['CookieSecret'])) != 32: raise ValueError()
except Exception: raise RuntimeError('Cookie secret must encode exactly 32 random bytes') from None
pfx=base64.b64decode(secret(c['CertificateSecret']),validate=True)
write(base/'tls.pfx',''); (base/'tls.pfx').write_bytes(pfx)
# No PFX password in shell arguments; Key Vault certificate backing PFX has none.
subprocess.run(['openssl','pkcs12','-in',str(base/'tls.pfx'),'-nodes','-nocerts','-passin','pass:','-out','/etc/nginx/cloudlab/key.pem'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['openssl','pkcs12','-in',str(base/'tls.pfx'),'-clcerts','-nokeys','-passin','pass:','-out','/etc/nginx/cloudlab/chain.pem'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if lab:
 fingerprint=subprocess.check_output(['openssl','x509','-in','/etc/nginx/cloudlab/chain.pem','-noout','-fingerprint','-sha1'],text=True).strip().split('=')[-1].replace(':','')
 if fingerprint.upper()!=lab['ServerThumbprint'].upper(): raise RuntimeError('Key Vault certificate differs from lab manifest')
 subprocess.run(['openssl','verify','-CAfile','/usr/local/share/ca-certificates/cloudlab-root.crt','/etc/nginx/cloudlab/chain.pem'],check=True,stdout=subprocess.DEVNULL)
else:
 # Preserve intermediate CA certificates for the original public-CA mode.
 chain=subprocess.check_output(['openssl','pkcs12','-in',str(base/'tls.pfx'),'-cacerts','-nokeys','-passin','pass:'],stderr=subprocess.DEVNULL)
 with open('/etc/nginx/cloudlab/chain.pem','ab') as stream: stream.write(chain)
(base/'tls.pfx').unlink()
for host in [c['AppHost'],c['AuthHost'],c['BackendHost']]:
 subprocess.run(['openssl','x509','-in','/etc/nginx/cloudlab/chain.pem','-noout','-checkhost',host],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['openssl','x509','-in','/etc/nginx/cloudlab/chain.pem','-noout','-checkend','604800'],check=True,stdout=subprocess.DEVNULL)
# Password only enters psql via stdin (never process arguments or deployment logs).
subprocess.run(['systemctl','enable','--now','postgresql'],check=True,stdout=subprocess.DEVNULL)
sql="SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='keycloak')\\gexec\n"
sql+="ALTER ROLE keycloak PASSWORD '"+values['DbPasswordSecret']+"';\n"
sql+="SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='keycloak')\\gexec\n"
subprocess.run(['runuser','-u','postgres','--','psql','-v','ON_ERROR_STOP=1'],input=sql,text=True,check=True,stdout=subprocess.DEVNULL)
# Only first boot imports the realm. Never overwrite live users/roles on reruns.
realm={'realm':k['Realm'],'enabled':True,'sslRequired':'external','registrationAllowed':False,'resetPasswordAllowed':False,'bruteForceProtected':True,'browserFlow':'cloudlab-mfa',
'roles':{'realm':[{'name':k['AllowedRole']}]},
'requiredActions':[{'alias':'CONFIGURE_TOTP','name':'Configure OTP','providerId':'CONFIGURE_TOTP','enabled':True,'defaultAction':True,'priority':10}],
'authenticationFlows':[
 {'alias':'cloudlab-mfa','providerId':'basic-flow','topLevel':True,'builtIn':False,'authenticationExecutions':[
  {'authenticator':'auth-cookie','requirement':'ALTERNATIVE','priority':10,'authenticatorFlow':False},
  {'flowAlias':'cloudlab-mfa-forms','requirement':'ALTERNATIVE','priority':20,'authenticatorFlow':True}]},
 {'alias':'cloudlab-mfa-forms','providerId':'basic-flow','topLevel':False,'builtIn':False,'authenticationExecutions':[
  {'authenticator':'auth-username-password-form','requirement':'REQUIRED','priority':10,'authenticatorFlow':False},
  {'authenticator':'auth-otp-form','requirement':'REQUIRED','priority':20,'authenticatorFlow':False}]}],
'clients':[{'clientId':k['ClientId'],'enabled':True,'protocol':'openid-connect','publicClient':False,'secret':values['ClientSecret'],'standardFlowEnabled':True,'directAccessGrantsEnabled':False,'serviceAccountsEnabled':False,'fullScopeAllowed':True,'redirectUris':['https://'+c['AppHost']+'/oauth2/callback'],'webOrigins':['https://'+c['AppHost']],'attributes':{'pkce.code.challenge.method':'S256'},'defaultClientScopes':['profile','email','roles'],'protocolMappers':[{'name':'proxy-audience','protocol':'openid-connect','protocolMapper':'oidc-audience-mapper','config':{'included.client.audience':k['ClientId'],'id.token.claim':'true','access.token.claim':'true'}}]}]}
realmtext=json.dumps(realm,sort_keys=True)
fingerprint=hashlib.sha256(realmtext.encode()).hexdigest()
fp=base/'realm.sha256'
if fp.exists() and fp.read_text()!=fingerprint: raise RuntimeError('Realm/client drift: use a reviewed Keycloak admin change; import does not update existing realms')
write(base/'realm.json',realmtext)
write(base/'realm.pending',fingerprint)
write(base/'keycloak.env','KC_DB_PASSWORD='+values['DbPasswordSecret']+'\nKC_BOOTSTRAP_ADMIN_USERNAME=bootstrap-admin\nKC_BOOTSTRAP_ADMIN_PASSWORD='+values['BootstrapPasswordSecret']+'\n')
write(base/'oauth.env','OAUTH2_PROXY_CLIENT_SECRET='+values['ClientSecret']+'\nOAUTH2_PROXY_COOKIE_SECRET='+values['CookieSecret']+'\n')
write(base/'install.env','\n'.join(a+'='+shlex.quote(str(v)) for a,v in {'KC_VERSION':k['Version'],'KC_SHA':k['Sha256'],'PROXY_VERSION':k['ProxyVersion'],'PROXY_SHA':k['ProxySha256']}.items())+'\n')
# /etc/hosts affects only backend lookup; public app name still resolves to Gateway.
hosts=pathlib.Path('/etc/hosts'); lines=[l for l in hosts.read_text().splitlines() if '# cloudlab-managed' not in l]
lines.append(c['App']['Ip']+' '+c['BackendHost']+' # cloudlab-managed')
if lab:
 lines.append('127.0.0.1 '+c['AuthHost']+' # cloudlab-managed')
hosts.write_text('\n'.join(lines)+'\n')
PYTHON
# shellcheck source=/dev/null
source /etc/cloudlab/install.env
if ! id keycloak >/dev/null 2>&1; then useradd --system --home /var/lib/keycloak --shell /usr/sbin/nologin keycloak; fi
if ! id oauth2-proxy >/dev/null 2>&1; then useradd --system --home /nonexistent --shell /usr/sbin/nologin oauth2-proxy; fi
install -d -o keycloak -g keycloak -m 750 /var/lib/keycloak
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Refuse implicit upgrades: a rollback needs a compatible PostgreSQL backup.
if [[ -L /opt/keycloak/current && "$(readlink /opt/keycloak/current)" != "/opt/keycloak/releases/$KC_VERSION" ]]; then
 echo 'Keycloak version change requires an explicit upgrade/DB-backup plan.' >&2; exit 1
fi
if [[ ! -f "/opt/keycloak/releases/$KC_VERSION/.vt-complete" ]]; then
 curl --fail --silent --show-error --location --retry 3 "https://github.com/keycloak/keycloak/releases/download/$KC_VERSION/keycloak-$KC_VERSION.tar.gz" -o "$work/keycloak.tgz"
 printf '%s  %s\n' "$KC_SHA" "$work/keycloak.tgz" | sha256sum --check --status
 tar -xzf "$work/keycloak.tgz" -C "$work"
 install -d "/opt/keycloak/releases/$KC_VERSION"
 cp -a "$work/keycloak-$KC_VERSION/." "/opt/keycloak/releases/$KC_VERSION/"
 /opt/keycloak/releases/"$KC_VERSION"/bin/kc.sh build --db=postgres --health-enabled=true >/dev/null
 touch "/opt/keycloak/releases/$KC_VERSION/.vt-complete"
fi
ln -sfn "/opt/keycloak/releases/$KC_VERSION" /opt/keycloak/current
install -d -o keycloak -g keycloak -m 750 /var/lib/keycloak/import
cp /etc/cloudlab/realm.json /var/lib/keycloak/import/cloudlab-realm.json
chown keycloak:keycloak /var/lib/keycloak/import/cloudlab-realm.json
# Writable runtime data only; binaries remain root-owned.
if [[ -d /opt/keycloak/current/data && ! -L /opt/keycloak/current/data ]]; then
 cp -a /opt/keycloak/current/data/. /var/lib/keycloak/
 rm -rf /opt/keycloak/current/data
fi
ln -sfn /var/lib/keycloak /opt/keycloak/current/data
chown -R keycloak:keycloak /var/lib/keycloak
curl --fail --silent --show-error --location --retry 3 "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v$PROXY_VERSION/oauth2-proxy-v$PROXY_VERSION.linux-amd64.tar.gz" -o "$work/proxy.tgz"
printf '%s  %s\n' "$PROXY_SHA" "$work/proxy.tgz" | sha256sum --check --status
tar -xzf "$work/proxy.tgz" -C "$work"
install -m 755 "$work/oauth2-proxy-v$PROXY_VERSION.linux-amd64/oauth2-proxy" /opt/oauth2-proxy/oauth2-proxy.new
mv /opt/oauth2-proxy/oauth2-proxy.new /opt/oauth2-proxy/oauth2-proxy
python3 - <<'PYTHON'
import json,pathlib
c=json.loads(pathlib.Path('/etc/cloudlab/config.json').read_text()); k=c['Keycloak']
def write(p,s,mode=0o644):
 path=pathlib.Path(p); path.write_text(s); path.chmod(mode)
write('/opt/keycloak/current/conf/keycloak.conf',f"""db=postgres
db-url=jdbc:postgresql://127.0.0.1:5432/keycloak
db-username=keycloak
hostname=https://{c['AuthHost']}
hostname-strict=true
http-enabled=true
http-host=127.0.0.1
http-port=8080
http-management-host=127.0.0.1
http-management-port=9000
proxy-headers=xforwarded
proxy-trusted-addresses=127.0.0.1
""")
write('/etc/cloudlab/oauth2-proxy.cfg',f"""provider = "keycloak-oidc"
http_address = "127.0.0.1:4180"
oidc_issuer_url = "https://{c['AuthHost']}/realms/{k['Realm']}"
client_id = "{k['ClientId']}"
redirect_url = "https://{c['AppHost']}/oauth2/callback"
upstreams = ["https://{c['BackendHost']}/"]
email_domains = ["*"]
allowed_roles = ["{k['AllowedRole']}"]
code_challenge_method = "S256"
scope = "openid profile email"
cookie_name = "__Host-cloudlab"
cookie_secure = true
cookie_httponly = true
cookie_samesite = "lax"
cookie_expire = "8h"
cookie_refresh = "5m"
reverse_proxy = true
skip_provider_button = true
pass_host_header = false
pass_user_headers = false
pass_access_token = false
pass_authorization_header = false
set_authorization_header = false
proxy_websockets = true
""")
for service,user,cmd,env in [('keycloak','keycloak','/opt/keycloak/current/bin/kc.sh start --optimized --import-realm','keycloak.env'),('oauth2-proxy','oauth2-proxy','/opt/oauth2-proxy/oauth2-proxy --config=/etc/cloudlab/oauth2-proxy.cfg','oauth.env')]:
 write('/etc/systemd/system/'+service+'.service',f"""[Unit]
Description=CloudLab {service}
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
User={user}
Group={user}
EnvironmentFile=/etc/cloudlab/{env}
ExecStart={cmd}
Restart=on-failure
RestartSec=10
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/keycloak
[Install]
WantedBy=multi-user.target
""")
# nginx can read root-only TLS private key before dropping privileges.
headers="""proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-Port 443;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header Forwarded "";
proxy_set_header X-Forwarded-Prefix "";
proxy_set_header X-Forwarded-User "";
proxy_set_header X-Forwarded-Email "";
proxy_set_header X-Forwarded-Groups "";
proxy_set_header X-Forwarded-Access-Token "";
proxy_set_header X-Auth-Request-User "";
proxy_set_header X-Auth-Request-Email "";
"""
write('/etc/nginx/cloudlab/proxy-headers.conf',headers)
tls="""ssl_certificate /etc/nginx/cloudlab/chain.pem;
ssl_certificate_key /etc/nginx/cloudlab/key.pem;
ssl_protocols TLSv1.2 TLSv1.3;
"""
# Local OIDC discovery uses the same issuer/SNI name and validates the lab CA.
# Only loopback gets port 443; external gateway traffic still uses port 8443.
auth_local_listen='listen 127.0.0.1:443 ssl;' if c.get('LabTls') else ''
server=f"""map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
server {{ listen 8443 ssl default_server; server_name _; {tls} return 444; }}
server {{
 listen 8443 ssl; {auth_local_listen} server_name {c['AuthHost']}; {tls}
 location = /_gateway_health {{ allow {c['Subnets']['AppGatewaySubnet']}; deny all; proxy_pass http://127.0.0.1:9000/health/ready; }}
 location ^~ /realms/{k['Realm']}/ {{ include /etc/nginx/cloudlab/proxy-headers.conf; proxy_pass http://127.0.0.1:8080; }}
 location ^~ /resources/ {{ include /etc/nginx/cloudlab/proxy-headers.conf; proxy_pass http://127.0.0.1:8080; }}
 location / {{ return 404; }}
}}
server {{
 listen 8443 ssl; server_name {c['AppHost']}; {tls}
 client_max_body_size 100m;
 location = /_gateway_health {{ allow {c['Subnets']['AppGatewaySubnet']}; deny all; proxy_pass http://127.0.0.1:4180/ready; }}
 location / {{
  include /etc/nginx/cloudlab/proxy-headers.conf;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_read_timeout 120s;
  proxy_pass http://127.0.0.1:4180;
 }}
}}
"""
write('/etc/nginx/sites-available/cloudlab',server)
# Admin access is deliberately absent here. Use private SSH tunneling; see README.
PYTHON
# Only remove the vendor's default site, never unrelated sites.
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/cloudlab /etc/nginx/sites-enabled/cloudlab
chmod 755 /etc/cloudlab
chmod 600 /etc/cloudlab/*.env /etc/cloudlab/*.json /etc/nginx/cloudlab/key.pem
chmod 644 /etc/cloudlab/oauth2-proxy.cfg
nginx -t >/dev/null 2>&1
systemctl daemon-reload
systemctl enable keycloak nginx oauth2-proxy >/dev/null
systemctl restart keycloak
ready=0
for ((i=0;i<90;i++)); do
 if curl --fail --silent http://127.0.0.1:9000/health/ready >/dev/null; then ready=1; break; fi
 sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Keycloak readiness failed.' >&2; exit 1; }
mv /etc/cloudlab/realm.pending /etc/cloudlab/realm.sha256
rm -f /etc/cloudlab/realm.json /var/lib/keycloak/import/cloudlab-realm.json
# Bootstrap credentials are only needed for initial startup.
sed -i '/^KC_BOOTSTRAP_ADMIN_/d' /etc/cloudlab/keycloak.env
systemctl restart keycloak
systemctl restart nginx
systemctl restart oauth2-proxy
ready=0
for ((i=0;i<90;i++)); do
 if curl --fail --silent http://127.0.0.1:9000/health/ready >/dev/null && curl --fail --silent http://127.0.0.1:4180/ready >/dev/null; then ready=1; break; fi
 sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Auth proxy readiness failed. Check DNS, certificate, issuer, and service logs.' >&2; exit 1; }
systemctl is-active --quiet keycloak nginx oauth2-proxy postgresql
