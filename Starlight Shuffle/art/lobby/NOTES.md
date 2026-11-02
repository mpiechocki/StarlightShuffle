# Lobby art (sources)

The pastel arcade lobby kit the lobby scene is built from: `build_lobby.py`
(the kit's procedural source, Python 3 + numpy), `import_to_blender.py`,
the kit's `README.txt` and `manifest.json`. This folder is outside `assets/`,
so the build does not ship it.

The game ships the kit's individual models in `assets/models/lobby/` (all
but the unused controller pillow), placed in `scenes/lobby.json` exactly where
the kit's assembled `pastel_lobby.glb` has them. The room behind the arcade
doorway is built from scene boxes (the kit leaves it out). `sky_dome.glb` is
Sky Lounge's dome; its texture is painted by `tools/lobby_sky.py`.
