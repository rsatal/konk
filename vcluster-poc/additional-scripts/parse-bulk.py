import json
d = json.load(open('/tmp/bulk-deploy.json'))
spec = d['spec']['template']['spec']
c = spec['containers'][0]
print('=== Container:', c['name'], '===')
print('Image:', c['image'])
print()
print('=== Args ===')
for a in c.get('args', []):
    print('  ' + a)
print()
print('=== Env ===')
for e in c.get('env', []):
    val = e.get('value', str(e.get('valueFrom', '(ref)')))
    print('  ' + e['name'] + '=' + val)
print()
print('=== Volume Mounts ===')
for vm in c.get('volumeMounts', []):
    print('  ' + vm['name'] + ' -> ' + vm['mountPath'])
print()
print('=== Volumes ===')
for v in spec.get('volumes', []):
    secret = v.get('secret', {}).get('secretName', '')
    cm = v.get('configMap', {}).get('name', '')
    src = secret or cm or 'other'
    print('  ' + v['name'] + ' -> ' + src)
print()
print('=== All containers ===')
for c2 in spec.get('initContainers', []):
    print('  init: ' + c2['name'])
for c2 in spec['containers']:
    print('  main: ' + c2['name'])
