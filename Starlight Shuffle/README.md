# Starlight Shuffle

For coding agents and scripting guidance, read [AGENTS.md](AGENTS.md). It explains
the runtime, bindings, client/server boundaries, UI, components, and project tests.

Players gather in a **lobby**, then play a looping **cycle** of short multiplayer
**mini-games**, earning **Starlights** that are kept on a lifetime **leaderboard**.
Open this folder in Moonbase, sign in and press **Play** (the arrow beside it sets
the client count; pick the `lobby` profile to start the way a real launch does).

## Places

Every server instance runs the same server root (`server/Root.luau`) and is one
*place*, chosen by its hosting profile in `project.json`:

| Profile | Runs | Seats |
| --- | --- | --- |
| `lobby` (initial) | `server/Lobby.luau` in the `lobby` scene. Launches land here. | 24 |
| `cycle` | `server/Cycle.luau`: the mini-games, one after another. | 16 |

**Lobby.** Everyone walks around in their own outfit, as in Sky Lounge. The big gold
button on the back wall (**Start mini-games**) sends the player to a cycle with room,
the fullest first, starting one when none has; players pressing it within half a
second of each other go together. The blue board beside it, and the trophy button
in the HUD, open the **leaderboard**.

**Cycle.** Plays `shared/Games.luau` in order and loops. Each mini-game goes:
*intro* (its scene loads, everyone lands in it, "Up next" shows for 5 s) → *playing*
(its `duration`) → *results* (everyone's Starlights for it, 7 s). Arrivals join the
mini-game under way, unless it is already showing results. The HUD's head shows the
mini-game, its phase and time left, and the **Pause/Play** button: pressing Pause
marks you to leave, and when the current mini-game's results end you go back to the
lobby you came from (or any lobby with room). Pressing Play before then keeps you in.

**Idle stop.** The host never stops idle instances, so a place stops itself once it
has been empty for 30 s (cycle) or 300 s (lobby).

## Starlights and the leaderboard

`server/Starlights.luau` keeps every player's lifetime total in `@moonbase/storage`:
a sorted set ranks players, and a hash keeps the name each was last seen with. So
totals outlast sessions, places and launches. A cycle adds a mini-game's Starlights
in one storage operation when its results show; its id (instance and round) makes a
retried award count once. The HUD shows your total in every place; the leaderboard
lists the top 20 and your rank.

Local Play starts each run with an empty datastore, so totals reset between Play runs
there; within a run they carry across moves between places.

## Mini-games

Each mini-game has:

- a scene, `scenes/<id>.json`, with a `player-spawn` entity and a camera;
- a server module, `assets/scripts/minigames/<id>/Server.luau`: its rules, scoring
  and awards (the contract is in `server/Minigame.luau`);
- a client module, `assets/scripts/minigames/<id>/Client.luau`: its HUD, effects
  and taps (the contract is in `client/Minigame.luau`).

They talk to each other through `context.send(...)` on either side, which arrives as
`receive(...)` on the other (the server's also names the player). The cycle owns the
scene loading, avatars, timing, results and Starlights; a mini-game only decides what
happens during play and calls `context.award(player, n)`.

The three mini-games here (`minigame_1`, `minigame_2`, `minigame_3`) are blank: players
walk around a coloured arena for 30 s, and everyone still there at the end earns
1 Starlight for taking part, so the leaderboard has something to show.

### Adding a mini-game

1. Create its scene (**Hierarchy → scene dropdown → New scene…**) named after its id,
   with a `player-spawn` entity, a camera and a floor. Either bake a navmesh for it or
   add a `walk-area` entity with the `gameplay/WalkArea` script (see below).
2. Copy a folder under `assets/scripts/minigames/` to `minigames/<id>/` and write
   its rules and HUD.
3. Add a row for it to `shared/Games.luau` (its place in that list is its place in
   the cycle), and a line each to `server/Games.luau` and `client/Games.luau`.

`tests/net_test.luau` checks that every listed mini-game is played and that its scene
is named after its id.

## Walking

Avatars use Sky Lounge's movement: the owner walks immediately with
`@moonbase/prediction`, and the server accepts a report only if it is on the floor and
within a speed budget (`server/Arena.luau`). The floor is the scene's baked navmesh
when it has one. These scenes do not have one yet; until they do, each one's
`walk-area` entity (`gameplay/WalkArea`, a width and depth) marks a walkable rectangle,
which `shared/Floor.luau` gives both sides. It has no obstacles, so avatars walk through
props on it. To use a real navmesh, open the scene and use **Bake navmesh**; it is
then used instead.

## Files

- `assets/scripts/Root.luau`: the client root. It wires the controllers, the HUD and
  the lobby's wall buttons.
- `assets/scripts/client/`: `Multiplayer` (the replicated world and every avatar in it),
  `Place` (which place you are in, the cycle's round, your Starlights, the leaderboard,
  moves between places, and routing to the current mini-game's client module),
  `Appearance` and `Roster`.
- `assets/scripts/widgets/`: `Hud` (with `Leaderboard`, `WallLabels` over the lobby's
  buttons, and the shared `Style`) and `WalkControls`.
- `assets/scripts/gameplay/`: movement, the follow camera and `WalkArea`, ported from
  Sky Lounge.
- `assets/scripts/server/`: `Root`, `Lobby`, `Cycle`, `Arena` (the scene and avatars;
  it swaps scenes between mini-games on one replication stream), `People` (who is here
  and how they look), `Starlights`, `Travel` (finding, starting and moving between
  places) and the mini-game registry `Games`.
- `assets/scripts/shared/`: `Net` (the wire protocol and its validators), `Games` (the
  mini-game list) and `Floor`.
- `assets/prefabs/Avatar.prefab`: every player's avatar, with its movement settings.

Project settings and Save are in the **Moonbase** menu. **Hosting** links a
PHP-managed experience when you are ready to upload, preview or publish; it is
not needed for local Play.

## VS Code

Open this project folder and install the recommended **Luau Language Server**
extension. `.luaurc` provides strict typing and the same module aliases as the
runtime. `.vscode/settings.json` loads the Moonbase, Flutter and script globals.
No application-repository checkout or Roblox tools are needed.

Moonbase maintains the bundled type support in `.moonbase/sdk/`. Reopening the
project restores missing configuration files and updates the generated SDK while
preserving your existing VS Code settings and `.luaurc`. Commit `project.json`,
scenes, scripts and asset `.meta` files; `.moonbase/` and `build/` are generated.
