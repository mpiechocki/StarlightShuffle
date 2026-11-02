PASTEL ARCADE LOBBY — EDITABLE 3D KIT

Contents
- pastel_lobby.glb: assembled lobby, individually named asset parents and mesh parts.
- asset_catalog.glb: assets spaced apart for inspection and editing.
- assets/: 22 individual GLB asset files.
- model-preview.png: actual mesh preview, rendered with the included software renderer.
- build_lobby.py: editable procedural source; requires Python 3 and numpy, plus Pillow for preview.
- import_to_blender.py: optional Blender helper to import the lobby, add a camera/lights, and save pastel_lobby.blend.
- manifest.json: exported object and triangle counts.

Open/edit in Blender
1. File > Import > glTF 2.0, then select pastel_lobby.glb (or any individual asset GLB).
2. Use the Outliner to select a named asset parent or individual mesh part.
3. Edit Mode changes vertices/faces; Material Properties changes the pastel colors.
4. File > Save As saves your editable .blend file.
The optional helper can also run from Blender's Scripting workspace or using:
blender --background --python import_to_blender.py
The helper clears the current scene, so run it in a new empty Blender file.
Blender was not installed in the creation environment, so the helper is provided unexecuted.

Conventions
- Units: metres; the main floor is approximately 16 by 10 metres.
- GLB uses standard glTF Y-up. A named root rotates the Z-up source geometry to Y-up.
- All objects are true editable triangle meshes, not flat image planes.
- Materials are named PBR base colors; gold has a mild metallic value.
- Sign lettering is editable mesh geometry, not a text/font object.
- Plant leaves, pillows, screen details and floor pixels are modeled geometry.
- The platform has a shallow cloud edge and no planet-shaped underside.

Scope and limitations
This is a manually scripted stylized approximation of the reference images, not an exact reconstruction.
Hidden surfaces and dimensions were inferred. Some forms and decorative details are simplified.
This kit is an editable starting point for further art direction, not a finished production game asset pack.
The lobby contains roughly 224,000 triangles and many separately editable parts; see manifest for exact counts.
No UV unwraps, baked texture atlases, LODs, collision meshes, rigs, animations, or interactive leaderboard/shop logic are included.
The GLBs contain meshes/materials. Environment lights and camera are supplied only by the optional Blender helper.
The software preview shows the geometry and palette; it does not reproduce the image concept's lighting.
The arcade cabinets stand beyond the central opening as reference props; extend the floor/walls if making that adjacent room walkable.

Regenerate
python build_lobby.py
This rewrites the generated GLBs, manifest and preview in this folder.
Edit the individual asset functions to adjust proportions, pieces, and colors.
