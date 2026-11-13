"""Builds the playable place from the base .rbxlx and the Lua sources in src/.

  python3 tools/place/build.py [base.rbxlx] [out.rbxlx]

Every Script / LocalScript / ModuleScript in the base place gets its Source from the matching
file in src/ (same instance path; .server.lua / .client.lua / .lua). Source files with no
instance in the base place become new ModuleScripts under their parent instance. The rest of the
place (stadium, lighting, settings) is copied byte for byte.
"""
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "src")
BASE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "place", "NewFootballStar.base.rbxlx")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "build", "NewFootballStar.rbxlx")
EXT = {"Script": ".server.lua", "LocalScript": ".client.lua", "ModuleScript": ".lua"}


def prop(item, name):
    props = item.find("Properties")
    for c in props if props is not None else []:
        if c.get("name") == name:
            return c.text or ""
    return None


def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


raw = open(BASE, encoding="utf-8").read()
root = ET.fromstring(raw)

scripts = []  # (path, class) in document order
items_by_path = {}  # path -> referent, for every instance


def walk(item, path):
    p = path + [prop(item, "Name") or "?"]
    items_by_path.setdefault(tuple(p), item.get("referent"))
    if item.get("class") in EXT:
        scripts.append((p, item.get("class")))
    for child in item.findall("Item"):
        walk(child, p)


for it in root.findall("Item"):
    walk(it, [])

# 1. Replace sources in document order.
pattern = re.compile(r'<ProtectedString name="Source">(.*?)</ProtectedString>', re.S)
matches = list(pattern.finditer(raw))
assert len(matches) == len(scripts), (len(matches), len(scripts))
known = set()
pieces, last = [], 0
for m, (path, cls) in zip(matches, scripts):
    fn = os.path.join(SRC, *path) + EXT[cls]
    known.add(os.path.normpath(fn))
    if not os.path.exists(fn):
        sys.exit(f"missing source for {'/'.join(path)}: {fn}")
    pieces.append(raw[last:m.start(1)])
    pieces.append(cdata(open(fn, encoding="utf-8").read()))
    last = m.end(1)
pieces.append(raw[last:])
raw = "".join(pieces)

# 2. New ModuleScripts for source files the base place does not have.
added = []
for dirpath, _, files in os.walk(SRC):
    for f in sorted(files):
        fn = os.path.normpath(os.path.join(dirpath, f))
        if fn in known or not f.endswith(".lua"):
            continue
        if f.endswith(".server.lua") or f.endswith(".client.lua"):
            sys.exit(f"new Script/LocalScript files are not supported: {fn}")
        rel = os.path.relpath(fn, SRC)[: -len(".lua")].split(os.sep)
        parent = items_by_path.get(tuple(rel[:-1]))
        if parent is None:
            sys.exit(f"no parent instance for new module {'/'.join(rel)}")
        item = (
            f'<Item class="ModuleScript" referent="RBX{uuid.uuid4().hex.upper()}">\n<Properties>\n'
            '<Content name="LinkedSource"><null></null></Content>\n'
            f'<ProtectedString name="Source">{cdata(open(fn, encoding="utf-8").read())}</ProtectedString>\n'
            f'<string name="ScriptGuid">{{{str(uuid.uuid4()).upper()}}}</string>\n'
            f'<string name="Name">{rel[-1]}</string>\n'
            f'<UniqueId name="UniqueId">{uuid.uuid4().hex}</UniqueId>\n'
            "</Properties>\n</Item>\n"
        )
        anchor = raw.index(f'referent="{parent}"')
        insert_at = raw.index("</Properties>", anchor) + len("</Properties>\n")
        raw = raw[:insert_at] + item + raw[insert_at:]
        added.append("/".join(rel))

ET.fromstring(raw)  # still well-formed
os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8").write(raw)
print(f"built {OUT}: {len(scripts)} scripts updated, {len(added)} added {added}")
