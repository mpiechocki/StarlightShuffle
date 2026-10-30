# Starlight Shuffle

For coding agents and scripting guidance, read [AGENTS.md](AGENTS.md). It explains
the runtime, bindings, client/server boundaries, UI, components, and project tests.

Open this folder in Moonbase. The `main` scene includes a camera, lights and a
rotating sculpture. Sign in and press **Play**; **Say hello** sends a message to
the server and prints its reply in the Play console.

- `assets/scripts/Root.luau` starts the client, loads the scene and builds the UI.
- `assets/scripts/server/Root.luau` handles the server side of the greeting.
- `assets/scripts/shared/Protocol.luau` names messages shared by both sides (unpinned).
- `assets/scripts/Spin.luau` is attached to the sculpture. Its speed is editable.
- `scenes/main.json` contains the authored scene; `project.json` selects the client and server roots; `--@client` / `--@server` headers pin scripts to a side.
- `tests/` is for Luau tests; use **Tests** in the editor header to run them.

Use **Hierarchy → scene dropdown → New scene…** to add scenes. Project settings
and Save are in the **Moonbase** menu. **Hosting** links a PHP-managed experience
when you are ready to upload, preview or publish; it is not needed for local Play.

## VS Code

Open this project folder and install the recommended **Luau Language Server**
extension. `.luaurc` provides strict typing and the same module aliases as the
runtime. `.vscode/settings.json` loads the Moonbase, Flutter and script globals.
No application-repository checkout or Roblox tools are needed.

Moonbase maintains the bundled type support in `.moonbase/sdk/`. Reopening the
project restores missing configuration files and updates the generated SDK while
preserving your existing VS Code settings and `.luaurc`. Commit `project.json`,
scenes, scripts and asset `.meta` files; `.moonbase/` and `build/` are generated.
