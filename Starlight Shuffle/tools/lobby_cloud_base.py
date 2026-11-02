#!/usr/bin/env python3
"""Builds assets/models/lobby/cloud_base.glb: the puffy cloud the lobby's
platform floats on, as in the lobby renders (the kit's platform has only a
shallow cloud rim). Overlapping squashed spheres in two rows along the
platform's edge and a fuller mass beneath, in two soft pastel materials.
Seeded, so it rebuilds the same. Standard library only. Run from the project
folder: python3 tools/lobby_cloud_base.py
"""
import json, math, os, random, struct

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "models", "lobby", "cloud_base.glb")
rng = random.Random(11)
HALF_X, HALF_Z, BACK_Z = 8.0, 5.1, -7.4  # the platform's edge (and the arcade's back)

def sphere(cx, cy, cz, r, squash, seg=10, rings=7):
    verts, norms, tris = [], [], []
    for j in range(rings + 1):
        t = math.pi * j / rings
        for i in range(seg):
            p = 2 * math.pi * i / seg
            nx, ny, nz = math.sin(t) * math.cos(p), math.cos(t), math.sin(t) * math.sin(p)
            verts.append((cx + nx * r, cy + ny * r * squash, cz + nz * r))
            n = (nx, ny / squash, nz); l = math.sqrt(sum(c * c for c in n)); norms.append(tuple(c / l for c in n))
    for j in range(rings):
        for i in range(seg):
            a, b = j * seg + i, j * seg + (i + 1) % seg
            c, d = a + seg, b + seg
            if j > 0: tris.append((a, b, c))
            if j < rings - 1: tris.append((b, d, c))
    return verts, norms, tris

def edge_points(step):
    # Around the platform's outline (with the arcade's alcove at the back).
    pts = []
    path = [(-HALF_X, HALF_Z), (HALF_X, HALF_Z), (HALF_X, -HALF_Z), (2.1, -HALF_Z), (2.1, BACK_Z), (-2.1, BACK_Z), (-2.1, -HALF_Z), (-HALF_X, -HALF_Z)]
    for (x0, z0), (x1, z1) in zip(path, path[1:] + path[:1]):
        n = max(1, int(math.hypot(x1 - x0, z1 - z0) / step))
        for k in range(n): pts.append((x0 + (x1 - x0) * k / n, z0 + (z1 - z0) * k / n))
    return pts

puffs = {"cloud": [], "cloud_shade": []}
for x, z in edge_points(0.75):
    puffs["cloud"].append((x + rng.uniform(-0.1, 0.1), -0.58 + rng.uniform(-0.04, 0.04), z + rng.uniform(-0.1, 0.1), rng.uniform(0.5, 0.78), 0.72))
for x, z in edge_points(1.1):
    puffs["cloud_shade"].append((x * 0.93, -0.95 + rng.uniform(-0.08, 0.08), z * 0.93 if z > BACK_Z + 0.1 else z + 0.3, rng.uniform(0.75, 1.05), 0.7))
for _ in range(46):
    x, z = rng.uniform(-HALF_X * 0.85, HALF_X * 0.85), rng.uniform(-HALF_Z * 0.85, HALF_Z * 0.85)
    puffs["cloud_shade"].append((x, rng.uniform(-1.5, -1.0), z, rng.uniform(1.0, 1.6), 0.6))

COLORS = {"cloud": (0.96, 0.87, 0.95), "cloud_shade": (0.84, 0.74, 0.92)}
blobs, buffer_views, accessors, meshes_primitives = bytearray(), [], [], []
def add_view(data, target):
    while len(blobs) % 4: blobs.append(0)
    off = len(blobs); blobs.extend(data)
    buffer_views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
    return len(buffer_views) - 1
for m, (name, list_) in enumerate(puffs.items()):
    V, N, T = [], [], []
    for (cx, cy, cz, r, sq) in list_:
        v, n, t = sphere(cx, cy, cz, r, sq)
        base = len(V); V += v; N += n; T += [(a + base, b + base, c + base) for a, b, c in t]
    pv = add_view(b"".join(struct.pack("<3f", *p) for p in V), 34962)
    nv = add_view(b"".join(struct.pack("<3f", *p) for p in N), 34962)
    iv = add_view(b"".join(struct.pack("<3I", *t) for t in T), 34963)
    lo = [min(p[k] for p in V) for k in range(3)]; hi = [max(p[k] for p in V) for k in range(3)]
    accessors += [{"bufferView": pv, "componentType": 5126, "count": len(V), "type": "VEC3", "min": lo, "max": hi},
                  {"bufferView": nv, "componentType": 5126, "count": len(N), "type": "VEC3"},
                  {"bufferView": iv, "componentType": 5125, "count": len(T) * 3, "type": "SCALAR"}]
    a = len(accessors) - 3
    meshes_primitives.append({"attributes": {"POSITION": a, "NORMAL": a + 1}, "indices": a + 2, "material": m})
    print(name, len(T), "triangles")
gltf = {"asset": {"version": "2.0", "generator": "tools/lobby_cloud_base.py"}, "scene": 0,
        "scenes": [{"nodes": [0]}], "nodes": [{"name": "Cloud base", "mesh": 0}],
        "meshes": [{"name": "cloud_base", "primitives": meshes_primitives}],
        "materials": [{"name": n, "pbrMetallicRoughness": {"baseColorFactor": [*COLORS[n], 1], "roughnessFactor": 0.95, "metallicFactor": 0}}
                      for n in puffs],
        "buffers": [{"byteLength": len(blobs)}], "bufferViews": buffer_views, "accessors": accessors}
js = json.dumps(gltf, separators=(",", ":")).encode()
js += b" " * ((4 - len(js) % 4) % 4)
while len(blobs) % 4: blobs.append(0)
with open(OUT, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blobs)))
    f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
    f.write(struct.pack("<II", len(blobs), 0x004E4942)); f.write(bytes(blobs))
print("wrote", OUT)
