#!/usr/bin/env python3
import subprocess, json, base64, yaml, tempfile, os

# Get the vcluster kubeconfig from the secret
result = subprocess.run(
    ["kubectl", "get", "secret", "tagging-aggregate-api-vcluster-kubeconfig",
     "-n", "tagging-v2", "-o", "json"],
    capture_output=True, text=True
)
secret = json.loads(result.stdout)
kubeconfig_raw = base64.b64decode(secret['data']['admin.conf']).decode()
kc = yaml.safe_load(kubeconfig_raw)

# Extract client cert, key, and CA from kubeconfig/tmp/fix-proxy-client.py
client_cert = base64.b64decode(kc['users'][0]['user']['client-certificate-data']).decode()
client_key = base64.b64decode(kc['users'][0]['user']['client-key-data']).decode()
ca_cert = base64.b64decode(kc['clusters'][0]['cluster']['certificate-authority-data']).decode()

print("Client cert:")
with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as f:
    f.write(client_cert)
    cert_path = f.name
os.system(f"openssl x509 -noout -subject -issuer -dates -in {cert_path}")
os.unlink(cert_path)

# Write cert files
with open('/tmp/vc-client.crt', 'w') as f:
    f.write(client_cert)
with open('/tmp/vc-client.key', 'w') as f:
    f.write(client_key)
with open('/tmp/vc-ca.crt', 'w') as f:
    f.write(ca_cert)

print("\nFiles written to /tmp/vc-client.crt, /tmp/vc-client.key, /tmp/vc-ca.crt")
