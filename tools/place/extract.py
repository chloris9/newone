import xml.etree.ElementTree as ET, os, sys
F = sys.argv[1]
out = sys.argv[2]
root = ET.parse(F).getroot()

def name(item):
    p = item.find('Properties')
    if p is None:
        return '?'
    for c in p:
        if c.get('name') == 'Name':
            return c.text or ''
    return '?'

EXT = {'Script': '.server.lua', 'LocalScript': '.client.lua', 'ModuleScript': '.lua'}

def walk(item, path, d):
    cls = item.get('class'); n = name(item)
    p = path + [n]
    if cls in EXT:
        src = ''
        for c in item.find('Properties'):
            if c.get('name') == 'Source':
                src = c.text or ''
        fn = os.path.join(out, *p) + EXT[cls]
        os.makedirs(os.path.dirname(fn), exist_ok=True)
        open(fn, 'w').write(src)
        print('  ' * d + cls, n, len(src.splitlines()), 'lines')
    elif cls not in ('Part', 'MeshPart', 'UnionOperation') or d < 3:
        print('  ' * d + cls, n)
    for ch in item.findall('Item'):
        walk(ch, p, d + 1)

for it in root.findall('Item'):
    walk(it, [], 0)
