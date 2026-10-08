"""Exercise generated Linux configuration without writing system files."""
import json
import pathlib
import re
import tomllib
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]

class LabTlsTests(unittest.TestCase):
    def test_generated_proxy_config_in_both_modes(self):
        source = (ROOT / 'Scripts/Linux/Install-Keycloak.sh').read_text()
        blocks = re.findall(r"python3 - <<'PYTHON'\n(.*?)\nPYTHON", source, re.S)
        self.assertEqual(len(blocks), 2)
        for block in blocks:
            compile(block, 'embedded-python', 'exec')
        for lab in (False, True):
            config = {'AuthHost': 'auth.cloudlab.test', 'AppHost': 'app.cloudlab.test',
                      'BackendHost': 'backend.cloudlab.test',
                      'Keycloak': {'Realm': 'lab', 'ClientId': 'lab-proxy', 'AllowedRole': 'lab-user'},
                      'Subnets': {'AppGatewaySubnet': '10.40.1.0/24'}}
            if lab:
                config['LabTls'] = {'RootThumbprint': 'test'}
            written = {}
            def write(path, text, *args, **kwargs):
                written[str(path).replace('\\', '/')] = text
            with patch.object(pathlib.Path, 'read_text', return_value=json.dumps(config)), \
                 patch.object(pathlib.Path, 'write_text', write), \
                 patch.object(pathlib.Path, 'chmod'):
                exec(compile(blocks[1], 'generated-config', 'exec'), {})
            proxy = tomllib.loads(written['/etc/cloudlab/oauth2-proxy.cfg'])
            self.assertEqual(proxy['oidc_issuer_url'], 'https://auth.cloudlab.test/realms/lab')
            self.assertEqual(proxy['upstreams'], ['https://backend.cloudlab.test/'])
            self.assertFalse(proxy.get('ssl_insecure_skip_verify', False))
            self.assertFalse(proxy.get('ssl_upstream_insecure_skip_verify', False))
            nginx = written['/etc/nginx/sites-available/cloudlab']
            self.assertEqual('listen 127.0.0.1:443 ssl;' in nginx, lab)
            self.assertNotIn('listen 443 ssl;', nginx)
            self.assertIn('listen 8443 ssl;', nginx)

    def test_gateway_trust_is_optional_and_referenced(self):
        template = json.loads((ROOT / 'Templates/gateway.json').read_text())
        self.assertEqual(template['parameters']['trustedRootData']['defaultValue'], '')
        gateway = next(x for x in template['resources'] if x['type'].endswith('/applicationGateways'))
        self.assertIn('lab-root', gateway['properties']['trustedRootCertificates'])
        for settings in gateway['properties']['backendHttpSettingsCollection']:
            self.assertEqual(settings['properties']['protocol'], 'Https')
            self.assertIn('/trustedRootCertificates/lab-root', settings['properties']['trustedRootCertificates'])
