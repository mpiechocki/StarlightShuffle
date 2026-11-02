#!/usr/bin/env python3
# Makes the lobby kit's signs read as in the kit's renders: the SHOP lettering
# gets its own deep plum material (the kit letters it in the shared gold, which
# nearly vanishes on cream), the leaderboard's display turns navy under its
# white lettering, the ARCADE lettering turns a deep warm tan with glowing
# stars (on the cream plaque from tools/lobby_arcade.py), and the cabinets'
# screens glow blue.
# Rewrites the models in assets/models/lobby in place; running it again is a
# no-op. Python 3 standard library only.
import json, os, struct, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'models', 'lobby')
# Name -> (base colour, emission or None).
MATERIALS = {
    'sign': ([0.22, 0.1, 0.34, 1], None),
    'board': ([0.16, 0.14, 0.34, 1], None),
    'letters': ([0.72, 0.45, 0.24, 1], [0.18, 0.08, 0.02]),
    'star': ([1.0, 0.86, 0.45, 1], [0.8, 0.6, 0.2]),
    'display': ([0.16, 0.2, 0.5, 1], [0.2, 0.36, 0.85]),
}
# Model -> (node name fragment, material) pairs.
RULES = {
    'arcade_doorway.glb': [('lettering', 'letters'), ('marquee star', 'star')],
    'shop_stall.glb': [('lettering', 'sign')],
    'leaderboard.glb': [('blue display', 'board')],
    'pink_arcade.glb': [('display', 'display')],
    'blue_arcade.glb': [('display', 'display')],
}

def chunks(data):
    at = 12
    while at < len(data):
        length, kind = struct.unpack('<II', data[at:at + 8])
        yield kind, data[at + 8:at + 8 + length]
        at += 8 + length

def material(gltf, name):
    color, emission = MATERIALS[name]
    entry = {"name": name, "pbrMetallicRoughness": {"baseColorFactor": color, "metallicFactor": 0, "roughnessFactor": 0.8}}
    if emission: entry["emissiveFactor"] = emission
    names = [m['name'] for m in gltf['materials']]
    if name in names:
        gltf['materials'][names.index(name)] = entry
    else:
        gltf['materials'].append(entry)
        names.append(name)
    return names.index(name)

def patch(path, rules):
    data = open(path, 'rb').read()
    parts = list(chunks(data))
    gltf = json.loads(parts[0][1])
    for fragment, name in rules:
        index = material(gltf, name)
        meshes = [node['mesh'] for node in gltf['nodes'] if 'mesh' in node and fragment in node.get('name', '')]
        if not meshes: sys.exit('%s: no "%s" mesh' % (path, fragment))
        for mesh in meshes:
            for primitive in gltf['meshes'][mesh]['primitives']:
                primitive['material'] = index
        print('%s: %d "%s" mesh(es) -> %s' % (os.path.basename(path), len(meshes), fragment, name))
    text = json.dumps(gltf, separators=(',', ':')).encode()
    text += b' ' * (-len(text) % 4)
    body = struct.pack('<II', len(text), 0x4E4F534A) + text
    for kind, chunk in parts[1:]:
        body += struct.pack('<II', len(chunk), kind) + chunk
    open(path, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)

for model, rules in RULES.items():
    patch(os.path.join(ROOT, model), rules)
