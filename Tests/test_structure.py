import ast,json,pathlib,re,subprocess,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class StructureTests(unittest.TestCase):
 def test_shell_and_embedded_python_parse(self):
  for p in (ROOT/'Scripts/Linux').glob('*.sh'):
   subprocess.run(['bash','-n',str(p)],check=True)
   for block in re.findall("python3 - <<'PYTHON'\n(.*?)\nPYTHON",p.read_text(),re.S): ast.parse(block)
 def test_gateway_tls_boundary(self):
  t=json.loads((ROOT/'Templates/gateway.json').read_text());g=t['resources'][1]['properties']
  self.assertEqual({x['properties']['port'] for x in g['frontendPorts']},{443})
  self.assertTrue(all(x['properties']['protocol']=='Https' for x in g['backendHttpSettingsCollection']))
 def test_realm_requires_otp(self):
  s=(ROOT/'Scripts/Linux/Install-Keycloak.sh').read_text()
  block=re.findall("python3 - <<'PYTHON'\n(.*?)\nPYTHON",s,re.S)[0]
  node=next(n for n in ast.parse(block).body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='realm' for t in n.targets))
  ns={'k':{'Realm':'lab','ClientId':'proxy','AllowedRole':'lab-user'},'c':{'AppHost':'app.example.com'},'values':{'ClientSecret':'test-only'}}
  exec(compile(ast.Module(body=[node],type_ignores=[]),'realm','exec'),ns)
  flows=ns['realm']['authenticationFlows']
  otp=[e for f in flows for e in f['authenticationExecutions'] if e.get('authenticator')=='auth-otp-form']
  self.assertEqual(len(otp),1);self.assertEqual(otp[0]['requirement'],'REQUIRED')
  self.assertFalse(ns['realm']['clients'][0]['directAccessGrantsEnabled'])
if __name__=='__main__':unittest.main()
