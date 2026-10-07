#!/usr/bin/env bash
set -euo pipefail
umask 077
python3 - <<'PYTHON'
import base64,json,os,pathlib,tarfile,tempfile,urllib.request,urllib.error,time,hashlib,shutil,subprocess
c=json.loads(base64.b64decode(os.environ['CL_CONFIG_B64']))
e=c['Export']; limit=int(e['MaxArchiveMB'])*1024**2
work=pathlib.Path(tempfile.mkdtemp(prefix='cloudlab-export-'))
try:
 paths=[]; total=0
 for text in e['KeycloakPaths']:
  p=pathlib.Path(text)
  if not p.is_absolute() or str(p)=='/' or not p.exists(): raise RuntimeError('Missing/invalid selected path')
  for f in [p]+(list(p.rglob('*')) if p.is_dir() else []):
   if f.is_symlink(): raise RuntimeError('Symlinks are not exported')
   if f.is_file():
    if f.suffix.lower() in ('.pfx','.p12','.pem','.key','.env','.crt','.cer'): raise RuntimeError('Certificate/key/secret file selected')
    total+=f.stat().st_size
    if total>limit: raise RuntimeError('Export exceeds size limit')
  paths.append(p)
 dump=work/'identity.dump'
 with dump.open('wb') as output:
  subprocess.run(['runuser','-u','postgres','--','pg_dump','-Fc','keycloak'],stdout=output,stderr=subprocess.DEVNULL,check=True)
 if total+dump.stat().st_size>limit: raise RuntimeError('Files plus identity database exceed export limit')
 archive=work/'export.tar.gz'
 with tarfile.open(archive,'w:gz') as tar:
  tar.add(dump,arcname='identity.dump')
  for i,p in enumerate(paths): tar.add(p,arcname=str(i),recursive=True)
 if archive.stat().st_size>limit: raise RuntimeError('Archive exceeds size limit')
 digest=hashlib.sha256(archive.read_bytes()).hexdigest()
 req=urllib.request.Request('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F',headers={'Metadata':'true'})
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 with opener.open(req,timeout=20) as response: token=json.load(response)['access_token']
 url='https://'+e['StorageAccount']+'.blob.core.windows.net/'+e['Container']+'/'+c['ExportRunId']+'/Keycloak.tar.gz'
 headers={'Authorization':'Bearer '+token,'x-ms-version':'2023-11-03','x-ms-blob-type':'BlockBlob','If-None-Match':'*','x-ms-meta-sha256':digest}
 data=archive.read_bytes()
 headers['Content-MD5']=base64.b64encode(hashlib.md5(data).digest()).decode()
 for attempt in range(18):
  try:
   with urllib.request.urlopen(urllib.request.Request(url,data=data,headers=headers,method='PUT'),timeout=120) as response: pass
   break
  except (urllib.error.URLError,TimeoutError):
   try:
    with urllib.request.urlopen(urllib.request.Request(url,headers={'Authorization':'Bearer '+token,'x-ms-version':'2023-11-03'},method='HEAD'),timeout=20) as response:
     if response.headers.get('x-ms-meta-sha256')==digest: break
   except urllib.error.URLError: pass
   if attempt==17: raise RuntimeError('Blob upload failed') from None
   time.sleep(10)
finally:
 shutil.rmtree(work)
PYTHON
