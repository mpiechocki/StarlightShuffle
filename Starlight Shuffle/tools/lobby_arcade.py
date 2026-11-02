#!/usr/bin/env python3
"""Builds assets/models/lobby/arcade_arch.glb: the arcade entrance as in the
lobby renders, laid over the kit's rectangular doorway (whose own trim the
scene hides). A wide cream frame with big rounded top corners and a gold inner
edge, lavender fill in the corners it leaves, a cream pill plaque behind the
ARCADE lettering, and the round pink rug with its star on the arcade floor.
Same origin as the doorway; +Z faces the lobby. Standard library only. Run
from the project folder: python3 tools/lobby_arcade.py
"""
import json, math, os, struct

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "models", "lobby", "arcade_arch.glb")
W, TOP, R = 1.40, 2.95, 0.75     # the opening: half width, height, corner radius
JAMB_X, HEADER_Y = 1.43, 3.0     # the kit doorway's opening
FRONT, BACK = 0.19, -0.19        # the kit wall's faces
BAND, BAND_Z = 0.24, 0.30        # the frame: width and front
BEAD, BEAD_Z = 0.05, 0.33        # the gold edge
RUG_Z, RUG_R = -1.3, 0.8         # the rug, behind the doorway

MATERIALS = {
    "cream": ((1.0, 0.949, 0.875), None), "gold": ((0.843, 0.678, 0.408), None),
    "lavender": ((0.714, 0.627, 0.863), None), "rug": ((0.93, 0.66, 0.88), None),
    "rug_edge": ((0.82, 0.8, 0.98), None), "rug_star": ((1.0, 0.9, 0.5), (0.5, 0.4, 0.12)),
}
parts = {name: ([], [], []) for name in MATERIALS}

def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

def tri(mat, a, b, c, na, nb=None, nc=None):
    """One triangle, wound to face its normal."""
    V, N, T = parts[mat]
    nb, nc = nb or na, nc or na
    if dot(cross(sub(b, a), sub(c, a)), (na[0] + nb[0] + nc[0], na[1] + nb[1] + nc[1], na[2] + nb[2] + nc[2])) < 0:
        b, c, nb, nc = c, b, nc, nb
    k = len(V); V += [a, b, c]; N += [na, nb, nc]; T.append((k, k + 1, k + 2))

def quad(mat, a, b, c, d, na, nb=None, nc=None, nd=None):
    nb, nc, nd = nb or na, nc or na, nd or na
    tri(mat, a, b, c, na, nb, nc); tri(mat, a, c, d, na, nc, nd)

def outline(w, top, r, steps=14):
    """The opening's edge, bottom left round to bottom right: (x, y, outward normal)."""
    pts = [(-w, 0.0, (-1.0, 0.0))]
    for cx, a0 in ((-w + r, math.pi), (w - r, math.pi / 2)):
        for i in range(steps + 1):
            a = a0 - (math.pi / 2) * i / steps
            pts.append((cx + r * math.cos(a), top - r + r * math.sin(a), (math.cos(a), math.sin(a))))
    pts.append((w, 0.0, (1.0, 0.0)))
    return pts

def at(p, d, z): return (p[0] + p[2][0] * d, p[1] + p[2][1] * d, z)

def ring(mat, pts, d0, d1, z0, z1):
    """A band round the outline from offset d0 to d1, its front at z1 and sides back to z0."""
    for p, q in zip(pts, pts[1:]):
        n_in = (-p[2][0], -p[2][1], 0.0); m_in = (-q[2][0], -q[2][1], 0.0)
        quad(mat, at(p, d0, z1), at(q, d0, z1), at(q, d1, z1), at(p, d1, z1), (0, 0, 1))
        quad(mat, at(p, d0, z0), at(q, d0, z0), at(q, d0, z1), at(p, d0, z1), n_in, m_in, m_in, n_in)
        quad(mat, at(p, d1, z0), at(q, d1, z0), at(q, d1, z1), at(p, d1, z1),
             (p[2][0], p[2][1], 0.0), (q[2][0], q[2][1], 0.0), (q[2][0], q[2][1], 0.0), (p[2][0], p[2][1], 0.0))

def slab(mat, poly, z0, z1):
    """A flat convex shape (x, y points, anticlockwise) from z0 to z1."""
    cx = sum(p[0] for p in poly) / len(poly); cy = sum(p[1] for p in poly) / len(poly)
    for p, q in zip(poly, poly[1:] + poly[:1]):
        tri(mat, (cx, cy, z1), (p[0], p[1], z1), (q[0], q[1], z1), (0, 0, 1))
        e = (q[0] - p[0], q[1] - p[1]); l = math.hypot(*e) or 1
        n = (e[1] / l, -e[0] / l, 0.0)
        quad(mat, (p[0], p[1], z0), (q[0], q[1], z0), (q[0], q[1], z1), (p[0], p[1], z1), n)

def disc(mat, poly, y0, y1, z):
    """A flat shape lying on the floor (x, z points round its centre) from y0 to y1."""
    cx = sum(p[0] for p in poly) / len(poly); cz = sum(p[1] for p in poly) / len(poly)
    for p, q in zip(poly, poly[1:] + poly[:1]):
        tri(mat, (cx, y1, z + cz), (p[0], y1, z + p[1]), (q[0], y1, z + q[1]), (0, 1, 0))
        e = (q[0] - p[0], q[1] - p[1]); l = math.hypot(*e) or 1
        n = (e[1] / l, 0.0, -e[0] / l)
        if dot(n, (p[0] - cx, 0, p[1] - cz)) < 0: n = (-n[0], 0.0, -n[2])
        quad(mat, (p[0], y0, z + p[1]), (q[0], y0, z + q[1]), (q[0], y1, z + q[1]), (p[0], y1, z + p[1]), n)

def circle(r, n=40): return [(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)) for i in range(n)]

# The frame and its gold edge.
edge = outline(W, TOP, R)
ring("cream", edge, 0.0, BAND, BACK, BAND_Z)
ring("gold", edge, 0.0, BEAD, BAND_Z - 0.01, BEAD_Z)
# Lavender in the corners between the rounded opening and the kit's square one,
# front and back, fanned from each corner.
for side in (-1, 1):
    corner = (side * JAMB_X, HEADER_Y)
    arc = [p for p in edge if p[1] > TOP - R - 1e-6 and p[0] * side >= -1e-6]
    for p, q in zip(arc, arc[1:]):
        for z, nz in ((FRONT, 1), (BACK, -1)):
            tri("lavender", (corner[0], corner[1], z), (p[0], p[1], z), (q[0], q[1], z), (0, 0, nz))
# The plaque: a cream pill behind the lettering and its stars.
pill = []
for cx, a0 in ((1.32 - 0.18, -math.pi / 2), (-1.32 + 0.18, math.pi / 2)):
    for i in range(13):
        a = a0 + math.pi * i / 12
        pill.append((cx + 0.18 * math.cos(a), 3.4 + 0.18 * math.sin(a)))
slab("cream", pill, FRONT - 0.01, 0.228)
# The rug: pink, a pale edge and a glowing star.
disc("rug_edge", circle(RUG_R + 0.08), 0.0, 0.026, RUG_Z)
disc("rug", circle(RUG_R), 0.0, 0.03, RUG_Z)
star = [((0.42 if i % 2 == 0 else 0.18) * math.cos(math.pi / 2 + math.pi * i / 5),
         -(0.42 if i % 2 == 0 else 0.18) * math.sin(math.pi / 2 + math.pi * i / 5)) for i in range(10)]
disc("rug_star", star, 0.0, 0.036, RUG_Z)

blobs, views, accessors, primitives, materials = bytearray(), [], [], [], []
def add_view(data, target):
    while len(blobs) % 4: blobs.append(0)
    off = len(blobs); blobs.extend(data)
    views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
    return len(views) - 1
for name, (V, N, T) in parts.items():
    if not T: continue
    color, emission = MATERIALS[name]
    mat = {"name": name, "pbrMetallicRoughness": {"baseColorFactor": [*color, 1], "roughnessFactor": 0.8, "metallicFactor": 0}}
    if emission: mat["emissiveFactor"] = list(emission)
    materials.append(mat)
    pv = add_view(b"".join(struct.pack("<3f", *p) for p in V), 34962)
    nv = add_view(b"".join(struct.pack("<3f", *n) for n in N), 34962)
    iv = add_view(b"".join(struct.pack("<3I", *t) for t in T), 34963)
    lo = [min(p[k] for p in V) for k in range(3)]; hi = [max(p[k] for p in V) for k in range(3)]
    accessors += [{"bufferView": pv, "componentType": 5126, "count": len(V), "type": "VEC3", "min": lo, "max": hi},
                  {"bufferView": nv, "componentType": 5126, "count": len(N), "type": "VEC3"},
                  {"bufferView": iv, "componentType": 5125, "count": len(T) * 3, "type": "SCALAR"}]
    a = len(accessors) - 3
    primitives.append({"attributes": {"POSITION": a, "NORMAL": a + 1}, "indices": a + 2, "material": len(materials) - 1})
    print(name, len(T), "triangles")
gltf = {"asset": {"version": "2.0", "generator": "tools/lobby_arcade.py"}, "scene": 0,
        "scenes": [{"nodes": [0]}], "nodes": [{"name": "Arcade arch", "mesh": 0}],
        "meshes": [{"name": "arcade_arch", "primitives": primitives}], "materials": materials,
        "buffers": [{"byteLength": len(blobs)}], "bufferViews": views, "accessors": accessors}
js = json.dumps(gltf, separators=(",", ":")).encode()
js += b" " * ((4 - len(js) % 4) % 4)
while len(blobs) % 4: blobs.append(0)
with open(OUT, "wb") as f:
    f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blobs)))
    f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
    f.write(struct.pack("<II", len(blobs), 0x004E4942)); f.write(bytes(blobs))
print("wrote", OUT)
