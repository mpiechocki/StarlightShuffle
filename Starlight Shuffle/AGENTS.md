# Building a Moonbase project

This guide is for coding agents and humans writing this project's Luau scripts,
Flutter UI, and server logic. Read `project.json`, `.luaurc`, the project README,
and relevant existing scripts before changing behavior. The installed SDK is the
reference for the API available in this editor version.

## Start here

1. Find the client root in `project.json.rootScript.script` and the server root
   in `project.json.server.root.script`. Resolve their `asset:<uuid>` references through
   script `.meta` sidecars. Do not assume root filenames.
2. Scripts ship to whichever side reaches them through the roots, scene
   attachments and literal `require`s. The `--@server` / `--@client` line in a
   script's header says which side it belongs to; unpinned scripts are shared.
   Folder names assign nothing.
3. Find the controller, widget, rule, or component that owns the feature. Extend
   it instead of introducing another owner of the same state or ticker.
4. Look up the exact imported module and signature in `.moonbase/sdk/` before
   using an API. Read the focused module, then its referenced definitions.
5. Implement, save, run relevant project tests, and Stop/Play to check the actual
   application. Report separately what was typechecked, tested, or played.

## Project files and references

| Location | Purpose |
| --- | --- |
| `project.json` | Roots, initial scene, root properties, layers, server startup and hosting settings |
| `assets/scripts/` | Project-owned code; `@project` resolves here |
| `assets/**.meta` | Asset identity/import settings; preserve when moving or renaming assets |
| `scenes/*.json` | Authored entity/component graphs; scenes do not have script entrypoints |
| `tests/` | Tests and fixtures; `@tests` resolves here |
| `.luaurc`, `tests/.luaurc`, `.vscode/` | Strict typing, module aliases, language-server settings |
| `.moonbase/sdk/` | Generated authoring SDK matching the editor; inspect it, do not edit it |
| `build/` | Generated release bundles; not source code |

New assets acquire `.meta` files when the editor scans them. Use their actual
identity when assigning roots or attaching scripts. Prefer the
editor for assignments; when editing JSON directly, preserve its schema, UUIDs,
and unrelated fields. Filesystem paths, `require` names, `asset:<uuid>` references,
and native `scene:<name>` references are distinct; check the receiving API.

Commit source, authored configuration, and sidecars. `.moonbase/` and `build/`
are generated. Opening the project synchronizes SDK files, repairing changes and
removing obsolete files. Existing `.luaurc` and VS Code settings are preserved;
old custom paths may need updating explicitly. Open the project folder in VS Code.

## Working through the editor MCP server

If an MCP connection is available, call `inspect_workspace` to identify the open
project, document ID, revision and Play state. Read `moonbase://guides/scene-edits`
and use `component_schemas` (filter `types`; opt into `includeSchema` for full shapes),
`script_schemas`, `scene_schema`, `authoring_choices`,
`inspect_scene` and `inspect_assets` before editing. Tool input/output schemas
describe complete shapes; `moonbase://guides/operations` lists arguments and defaults. The bundled version of this guide is `moonbase://guides/authoring`;
also read this project's own guide and README for project-specific conventions.

Use `apply_edits` for the open scene, with the inspected `documentId`,
`expectedRevision` and a unique `requestId`. A batch is one atomic undo step.
Reinspect after revision conflicts; retry an uncertain request with exactly the
same ID and arguments. Frame and capture the result with `frame_entities` and
`capture_viewport`, then `save_scene` when ready. Do not modify the open scene's
JSON behind the editor or discard unsaved changes without the user's choice.

Project settings belong to the running editor. Use `inspect_project_settings`,
then `update_project_settings` with its `settingsVersion` as
`expectedSettingsVersion`. Do not write `project.json` behind the editor.
The typed patch preserves omitted top-level sections and replaces each supplied
section completely. Stop Play first; re-inspect on `settings_conflict`.
Use these calls for roots/properties, initial scene and layers. `rootScript` and
`server.root` are both `{script, properties}` attachments; server root
properties may only be strings, numbers, integers, booleans or prefabs.
Server `startup` data is game-defined JSON; Moonbase's own settings fields are
strictly declared. Removing an in-use layer is rejected.

Write Luau/UI/server sources with filesystem tools, save them, then call
`refresh_assets` for import diagnostics. It does not perform strict typechecking
or reload project settings. Use `check_scripts` for saved-source Luau type errors
and `validate_project` to compile the complete release without starting Play.
Validation uses current editor settings and the open scene draft; other scenes,
scripts and assets come from disk. Both return jobs: poll `inspect_job` and check
both state and `result.passed`. `check_scripts` uses the editor's built-in Luau
analyzer; nothing needs installing. Use `check_script_source` to typecheck proposed
source before writing it.

`run_tests` runs saved files as a job. To iterate on one test, save,
`refresh_assets`, then pass `file` (project-relative, e.g. `tests/lobby_test.luau`)
and/or `name` (case-insensitive part of the full `Group > case` name); a selection
matching nothing fails the job. `start_play` requires the editor's signed-in
account. Call `inspect_play` for client IDs, loading/errors and content bounds;
use `capture_play` and `play_input` with a specific client ID to verify behavior.
To fill a text field, tap it, send `text`, then `textAction` to submit; `key`
events never edit or submit fields. Play keeps running while the editor window
is covered by other windows.
Tap/drag coordinates are logical pixels from that client's content top-left.
Divide screenshot pixels by `pixelRatio`; device-preview scaling is automatic.
`scene.viewport`, `pick` and `screenPointToRay` use **GameView-local logical
pixels**, which can have a UI offset within the client. Do not multiply by device
pixel ratio. `capture_viewport` still captures the editor scene. Check `play_logs`
after input and Stop/Play after code changes. Client IDs expire on Stop/removal.
For bandwidth, `play_network` reports bytes and rates per direction, client and
message kind, with record-key bytes; totals are cumulative, so read it before
and after a scenario and subtract.
The scene-edits guide is an overview; `scene_edit_schema(kind)` returns one exact
shape, and `apply_edits.inputSchema` declares all shapes.

## Runtime and bindings

Moonbase embeds **Luau**. Each client has its own VM connected to Flutter, Dart
objects, and the scene renderer. Each server instance has a separate native Luau
VM with its own players, clocks, scenes, and rules. Required modules are cached
within a VM; clients and servers never share a Lua table or live module state.

The editor compiles scripts and captures assets/settings into a release with
matching client/server bundles. Play and shipping use this compilation path.
Source changes do not patch a running session: Stop and Play again. Scene
replacement retains the client root and UI but invalidates old scene handles.
A new Play starts fresh runtime state.

Bindings expose a **selected** host API. Flutter/Dart implementations stay in the
host; generated Luau modules describe constructors, members, callbacks, and types.
Native modules have authoring facades too. Some return `(nil :: any)` cast to an
API type; the VM supplies the real implementation. These are not files to copy
into project scripts or execute with a stock Lua CLI.

Adding SDK declarations cannot add runtime functionality. Do not invent APIs from
general Flutter, Unity, Roblox, browser, or Node knowledge. Roblox globals such as
`Instance`, `workspace`, and `RemoteEvent` are not this API. There is no general
Dart reflection/import escape hatch. Use only exposed members.

### Finding an API

Paths below are relative to `.moonbase/sdk/`:

| Import/API | Reference |
| --- | --- |
| `@flutter/widgets`, `material`, `painting`, `services` | `packages/moonbase_bindings/generated/luau/flutter/` |
| `@dart/ui`, `@dart/core`, `@dart/async` | `packages/moonbase_bindings/generated/luau/dart/` |
| `@async/async` | `packages/moonbase_bindings/generated/luau/async/async.luau` |
| `@es/ui`, `@es/models`, `@es/session`, `@es/api`, `@es/items` | `packages/moonbase_bindings/generated/luau/es/` |
| `@flutter_luau/runtime` | `packages/moonbase_bindings/generated/luau/flutter_luau/runtime.luau` |
| `@icons/*`, `@fonts/app` | `packages/moonbase_bindings/generated/luau/icons/` and `fonts/` |
| Flutter/Dart instance members and nominal types | `packages/moonbase_bindings/generated/flutter_luau.d.luau` |
| `@moonbase/engine` | `packages/moonbase_runtime/luau/moonbase/engine.luau` and `packages/moonbase_runtime/generated/moonbase_engine.d.luau` |
| Other `@moonbase/*` modules | `packages/moonbase_runtime/luau/moonbase/` |
| Native server, scene, math, and value contracts | `packages/moonbase_core/contracts/` |
| Shared library implementations/types | `packages/moonbase_core/luau/` |
| Injected presentation `component` declaration | `packages/moonbase_runtime/definitions/script.d.luau` |

For a text input, inspect `TextField` in `flutter/material.luau`, its controller
in `flutter/widgets.luau`, then instance methods in `flutter_luau.d.luau`. Follow
the emitted signatures, including nullability and props-table arguments.

Typical conventions, subject to each signature:

- Named constructor arguments use a table: `w.Text({data = 'Hello'})`.
- Named constructors/static methods use dot calls: `p.EdgeInsets.all(12)`.
- Bound instance methods use colon calls: `controller:dispose()`.
- Some methods mix positional arguments and an options table. Do not guess.
- Some constructors expose `.new`; use `es.CircularButton.new({...})` for its
  constructor argument checking. Not every exported type is constructible.
- Bound objects are host handles, not mutable Lua records. Model/collection
  results may be read-only snapshots. Only assign exposed writable properties.
- Use `--!strict`, concrete records, optional types, and discriminated unions.
  Validate `unknown` at network/storage boundaries; a type cast is not validation.
  Do not copy declaration-only SDK casts into gameplay code to silence errors.

## Client, server, and shared boundaries

| Side | Responsibilities and surfaces |
| --- | --- |
| Client | UI, input, cameras, presentation, authenticated client APIs, device preferences; Flutter/Dart/Everskies bindings, `@moonbase/game`, `@moonbase/engine`, `@moonbase/client`, `@moonbase/preferences` |
| Server | Authoritative rules, membership, validation, persistence, instance coordination; `@moonbase/server`, `@moonbase/hosting`, `@moonbase/task`; the Everskies platform through `@moonbase/social` (blocks, friends, chat moderation), `@moonbase/economy` and `@moonbase/analytics` |
| Shared | Pure data/rules/protocols; shared native APIs including `@moonbase/scene`, `math`, `value`, `types`, and `movement` |

Use literal imports: `require('@project/shared/Protocol')` or
`require('../shared/Protocol')`. The build walks the import graph from the
client root, the server root and scene attachments: each module ships to the
sides that reach it, unreached modules ship nowhere, and reaching an API a side
lacks fails the build with the import chain.

Pin every module that belongs to one side: put `--@server` or `--@client` on its
own line right after `--!strict`, before the first statement. Reaching a pinned
module from the other side fails the build, so a client import can never ship
server rules, storage operations or secrets, and server code cannot grow a
dependency on presentation code. Leave only genuinely shared code unpinned:
`shared/` data, protocols and rules, and `scene.defineScript` components that
must run in both VMs. When you create a module, pin it in the same edit. Remove
a pin only when the module is meant to become shared. Keep test fixtures out of
release code.

## Runtime material changes

`entity.material` is the first Material component (or nil); `entity.materials`
lists them. A bound `engine.MaterialComponent` property has the same API.
`color`, `tint` and `emissive` are writable `0xRRGGBB` integers;
`emissiveIntensity` is a finite non-negative number. Changes apply before the
next rendered frame and do not modify authored scene data. An authored material
change resets runtime overrides. These materials control box/plane renderers;
imported models retain their embedded materials.
Textured materials use `tint` instead of `color`; emission affects lit materials.

```luau
local material = cube.material
if material then
    material.color = 0x33cc88
    material.emissive = 0x116633
    material.emissiveIntensity = 1.5
end
```

To swap materials or shaders at runtime, declare them as properties
(`--@property local highlight: engine.MaterialAsset`, or `engine.ShaderAsset`),
pick the asset in the inspector, and call `material:useMaterial(highlight)` /
`useShader(shader)` (`useSlotMaterial`/`useSlotShader` on model renderers).
Textures for shader parameters are `engine.Texture` properties passed to
`parameters:setTexture(key, texture)`. These APIs take handles, never
asset strings: the property is what makes the build ship the asset. Put a
property on the scene component that uses it; a root-script value stays loaded
for the whole session.

## Baked lighting

A Light whose `mode` is `baked` is lit only by the scene's lighting bake, never
at runtime: setting its properties from a script changes nothing, and until the
scene is baked it lights nothing (a release of such a scene fails). A
`stationary` light is baked too, with its shadows and bounces, but scripts can
still set its `intensity` and `color` (switch it off, tint it) and every
surface follows; moving it or changing its range, cone or decay from a script
leaves its baked light where it was baked, with a warning in Play. Mark
MeshRenderers that never move `static`: the bake gives them light maps and they
cast its shadows. A script that moves a static mesh keeps its light map: its
baked light moves with it. Bake with the editor's **Baked lighting** section or
`bake_lighting` over MCP; `inspect_lighting` reports whether the scene is
`unbaked` or `stale`. Baked light is diffuse only. See the Moonbase repository's
`docs/baked-lighting.md`.

## Client root and UI

The client root ends with `return engine.defineScript({...})`. It owns session UI,
controllers, and subscriptions. Its synchronous lifecycle callbacks are
`onCreate`, `onStart`, `onEnable`, `onUpdate(dt)`, `onDisable`, and `onDestroy`.
Implement only those needed. `dt` is seconds.

Mount UI with `runtime.runView(widget)`. Place `game.GameView()` in a bounded
Flutter layout and call `game.loadScene` for a scene. UI-only screens need not load
one. A scene needs an enabled active camera to render; a black viewport does not
mean the Lua UI stopped. Adapt the current root rather than adding a second one:

```luau
--!strict
--@client
local engine = require('@moonbase/engine')
local game = require('@moonbase/game')
local runtime = require('@flutter_luau/runtime')
local w = require('@flutter/widgets')

return engine.defineScript({
    onStart = function()
        runtime.runView(w.Column({children = {
            w.SafeArea({child = w.Text({data = 'My world'})}),
            w.Expanded({child = game.GameView()}),
        }}))
        game.loadScene(game.entryScene):andThen(function(scene: engine.Scene)
            print('Loaded ' .. scene.name)
        end, function(err: unknown, _stack: unknown)
            print('Scene load failed: ' .. tostring(err))
        end)
    end,
})
```

Keep rules outside widget `build` functions. Define stateful widget classes once
at module scope. Flutter owns State lifecycle; `self.widget` contains current
props and `self:setState` schedules rebuilding. A local variable change alone
does not rebuild UI. Example `assets/scripts/widgets/Counter.luau` (client):

```luau
--!strict
--@client
local w = require('@flutter/widgets')
local p = require('@flutter/painting')
type Props = {read label: string}
type Fields = {count: number}
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

return define('Counter', {
    createState = function(): Fields return {count = 0} end,
    build = function(self: State, _context: w.BuildContext): w.Widget
        return w.GestureDetector({
            onTap = function()
                self:setState(function() self.count += 1 end)
            end,
            child = w.Padding({padding = p.EdgeInsets.all(16),
                child = w.Text({data = self.widget.label .. ': ' .. tostring(self.count)}),
            }),
        })
    end,
})
```

Import and mount it with `Counter({label = 'Clicks'})`. Create controllers, focus
nodes, timers, and listeners once per State, then release them in `dispose`.
Keep the same listener function for removal. Guard late results with
`self.mounted` and, if needed, a request generation so old work cannot replace new
state. Subscribe/read stores in lifecycle hooks; `build` should not start requests.

Use stable keys for reordered lists. Rebuild affected subtrees rather than
remounting the root every frame. Use constraints, scrollables, and SafeArea for
phone/desktop layouts; do not assume browser CSS behavior.

Client futures use `:andThen`/`:catchError`; inspect `@dart/async` and the
definitions. Dart timers use `@dart/async` and `@dart/core.Duration`. Use
`game.clock()` or `onUpdate(dt)` for simulation time. Do not block lifecycle
callbacks waiting for futures or assume JavaScript `async`/`await` syntax.

The scene and `onUpdate` run at the full rate (60 per second) while the player
touches the game or its camera moves, and at 30 otherwise; minimized, at 10.
Always integrate with `dt` rather than assuming a rate. `game.preferPacing`
is a hint: `"smooth"` keeps the full rate (cutscenes, fast minigames),
`"relaxed"` stays at 30 even while the player interacts, and `"auto"` restores
the default. The last call wins; a minimized game stays slow regardless.

Import icons/fonts from catalogs such as `@icons/material`, `@icons/mdi`,
`@icons/honeybee`, and `@fonts/app`. Select literal members (`icons.check`,
`fonts.lato`); the compiler packages referenced glyphs/families. Dynamic choices
should use a table of explicit references, not computed namespace indexing.
Use `game.image(texture)` to show any `engine.Texture` property in Flutter UI.
For network images prefer `es.WebImage` from `@es/ui`: disk-cached, with loading
and error states. Put images or other widgets inside a line of text with
`w.Text.rich`, `p.TextSpan` and `w.WidgetSpan`; give a span a
`g.TapGestureRecognizer` from `@flutter/gestures` to make it tappable, and
dispose recognizers with their State.

`@es/session.user` is the authenticated client user. `@es/models` exposes selected
readable models/helpers, not arbitrary mutable account records. `@es/api` provides
supported authenticated REST/wardrobe APIs and cancellation tokens.
`@es/items` is the app's own item browser and picker. `items.browse({source,
kind})` browses a player's `"wardrobe"` or `"wishlist"` (another's with
`userId`), the `"store"` or the `"outlet"`, browsing only: a listenable with
pages (`loadMore`, `hasMore`), filters, sorts, tags and categories; rebuild
with a `ListenableBuilder` and `dispose()` it with its State.
`items.pick(options)` opens the app's trade item picker over the game and
resolves with `{variations, sets}` (one entry per copy) or nil when closed.
`items.rarities()` and `items.rarity(id)` list the app's item rarities without
a request. Editor Play browses and picks on the signed-in account with the
app's requests; simulated clients and tests use a fixture wardrobe, and tests
answer picks with `t:answerItemPicks`. These are client services; do not import them on the server or infer
unexposed methods.

### The app's loading screen

The Everskies app covers a launch with the experience's loading screen until the
root has started, the connection is up and no `game.loadScene` is in progress.
A game with nothing to show by then (a scene the server picks later, an avatar
still dressing) can keep it up: call `game.holdLoadingScreen()` in the root's
`onCreate` or `onStart`, and the release it returns once ready, on failure paths
too. Later the screen may be gone, and a hold taken then only warns. Holds may
overlap, a second release does nothing, and holds end with the session. The
screen lifts when the last hold is released, or 30 seconds after it would have
lifted without them (with a warning in the app's log); script errors and lost
connections still show the app's failure screen at once. Editor Play has no
loading screen and ignores holds.

```luau
local release = function() end
local unsubscribe: (() -> ())? = nil

return engine.defineScript({
    onStart = function()
        -- The server names the scene: keep the loading screen up until it shows.
        release = game.holdLoadingScreen()
        unsubscribe = client.onMessage(function(kind: unknown, scene: unknown)
            if kind ~= 'scene' or type(scene) ~= 'string' then return end
            game.loadScene(scene):andThen(function(_: engine.Scene) release() end,
                function(_err: unknown, _stack: unknown) release() end)
        end)
    end,
    onDestroy = function()
        if unsubscribe then unsubscribe(); unsubscribe = nil end
    end,
})
```

### Device preferences

`@moonbase/preferences` keeps small per-device settings (client only):
`preferences.experience` is this experience's, `preferences.global` is shared by
every experience on the device and needs namespaced keys such as
`graphics.quality` (`"low"`, `"medium"` or `"high"`; map it to your own
`envDiv`, SSAO and bloom). Call `get`, `set`, `remove` and `keys` with a colon,
plus `clear` on the experience scope. Values are strings, finite numbers or
booleans (`json.encode` a table); keys are dot-separated
`[A-Za-z0-9_-]` segments of up to 64 characters; a scope holds 128 keys and
16 KiB. Reads are synchronous from the root's first line, and writes save
themselves. Stored values are untrusted input: validate what `get` returns.
Account data (progress, unlocks) belongs in server `@moonbase/storage`. Each
editor Play client is its own device; **Clear preferences** under it resets it.

```luau
local preferences = require('@moonbase/preferences')
local muted = preferences.experience:get('music.muted') == true
preferences.experience:set('music.muted', not muted)
```

## Components and authored properties

There are two component APIs, with different handles and transform representations.

**Presentation components** use `@moonbase/engine` and the injected `component`
local. `component.owner` is the entity; `component.transform` is its presentation
transform. The project root receives **nil** for `component`, despite its
non-optional editor declaration. Required helpers do not inherit the caller's
component: pass handles explicitly. Example client attachment:

```luau
--!strict
--@client
local engine = require('@moonbase/engine')
--@property(min = 0)
local speed: number = 0.45
local angle = 0

return engine.defineScript({
    onUpdate = function(dt: number)
        angle += dt * speed
        component.transform.rotation = vector.create(0, angle, 0)
    end,
})
```

**Native gameplay components** use `@moonbase/scene`. Their factory receives a
native component with `component.entity`, and runs on both sides unless its
header pins it with `--@server` or `--@client`:

```luau
--!strict
local scenes = require('@moonbase/scene')
--@property(min = 0)
local speed: number = 3

return scenes.defineScript(function(component)
    return {onUpdate = function(dt: number)
        local entity = component.entity
        entity:setWorldPosition(entity:worldPosition() + vector.create(speed * dt, 0, 0))
    end}
end)
```

Each attachment gets its own locals and injected properties. Required helpers
remain shared modules within that VM. Do not put per-entity mutable state in a
module singleton unless that sharing is deliberate.

Spawn prefabs from `scene.Prefab` properties, never names:
`--@property local crate: scene.Prefab`, then `world:spawn(crate)` (and
`replicas:track(entity, crate)` to replicate it). The property decides what
ships: a root's prefab (client or server root) is in the project bundle for
the whole session; a scene attachment's prefab ships inside that scene. Client
code shows one with `game.spawnVisual(scene, crate)` (plus `world:spawn(crate)`
for its native side); replication does both for tracked spawns. Spawned
entities get fresh IDs, so name them (`entity.name = 'player:' .. id`) and find
them with `scene:findEntity(name)`; `entity.avatarRenderer` dresses a spawned
avatar.

Place `--@property` immediately before a typed top-level local. The editor reads
the AST without executing it. Supported kinds include strings, booleans, finite
numbers, supported entity/component/texture references, and homogeneous lists.
Defaults are literals, literal lists, or nil. Numeric constraints include `min`,
`max`, and `integer`; use SDK-bound types for references. Root properties cannot
contain scene-local entity/component assignments.

Values with unchanged names/types survive reconciliation. Changing a default does
not reset an existing value; renaming a property is removal plus addition. Account
for authored values and save reconciled scenes/settings. Required unresolved
references and script errors block Play/build.

Instantiate native worlds with `scenes.instantiate('scene:<name>')`. They own
entities, colliders, navmeshes, scripts, and native handles. Native rotations use
quaternions from `@moonbase/math`; Euler rotations (scene files,
`transform.rotation`, `fromEuler`/`toEuler`) are radians applied as
`Ry(y) * Rx(x) * Rz(z)` (YXZ), so yaw reads back as any angle in (-π, π].
Transform getters return snapshots, not writable aliases; use the appropriate
setter. The server world owner calls `world:step(dt)` once per simulation step
and destroys it on teardown. The client host already steps the native world paired
with a loaded presentation scene; do not step it twice. Access it with
`game.nativeScene(renderingScene)`.

Navigation requires a baked `world.navMesh`; handle missing meshes and failed
paths. `navMesh:randomPoint({center = p, radius = r})` returns an evenly spread
walkable point reachable from `p` (no options: anywhere), or nil; `navMesh:bounds()`
returns the walkable `{min, max}`. Replacement/destruction invalidates old handles:
re-resolve or check `isValid` before using retained handles after asynchronous work.

## Server rules and messaging

The server root ends with `return server.defineScript({...})` from
`@moonbase/server`. Its callbacks are `onCreate`, `onStart`, `onUpdate(dt)`, and
`onDestroy`, without enable/disable hooks. Register messages/player events through
the server API. Subscriptions and `server.after` return cancellation functions.
Use `server.clock()`/`server.tick()` for simulation time and clean up owned resources.

Clients send intent with `client.notifyServer(...)`. The server receives
`(player, ...)`, replies with `server.notifyPlayers({player}, ...)`, or broadcasts
with `server.notifyPlayers(nil, ...)`. The host supplies the player: `session_id`
identifies a connection and `player_id` an account. Do not trust a claimed sender
in the payload. Validate shape, bounds, phase, ownership, rate, and revisions
before changing authoritative state.

Keep names/schemas in unpinned modules that both sides import. The starter's
`shared/Protocol.luau` exports `hello` and `welcome`. Example server root using
that protocol:

```luau
--!strict
--@server
local server = require('@moonbase/server')
local Protocol = require('../shared/Protocol')
local cancel: (() -> ())? = nil

return server.defineScript({
    onStart = function()
        cancel = server.onMessage(function(player: server.Player, kind: unknown)
            if kind ~= Protocol.hello then return end
            server.notifyPlayers({player}, Protocol.welcome, 'Hello from the server!')
        end)
    end,
    onDestroy = function()
        if cancel then cancel(); cancel = nil end
    end,
})
```

The client calls `client.notifyServer(Protocol.hello)` and subscribes using
`client.onMessage(function(kind: unknown, message: unknown) ... end)`. Validate
received data before updating the client store. Call the returned unsubscribe
function in the root's `onDestroy` or State's `dispose`. This greeting carries no
user payload; actual commands need explicit payload validation.

Messages are serialized copies delivered on later host turns, not synchronous
calls. Use serializable values. Handles, widgets, functions, threads, cycles,
sparse/mixed tables, and non-finite numbers cannot be payloads. `@moonbase/value`
provides explicit null and array markers: `{}` is a record; an empty array needs
`value.array()`. Send validated IDs/data instead of player/entity handles.

For world synchronization, inspect `@moonbase/replication` and client
`@moonbase/presentation` before inventing another mechanism. They handle scene
assignment, readiness, snapshots, generations, and changed transforms. Route their
messages through the dispatcher. Give scene loading one owner; replication should
not compete with independent root `game.loadScene` calls. Step the server world
before publishing replicas. Use `@moonbase/movement` and client
`@moonbase/prediction` where applicable, keeping cosmetics separate from authority.

### Hosting, persistence, and async server work

Games own room rules/schemas; host services own allocation, connections, storage
operations, and transfers. Inspect `project.json.server` and
`server.context.profile_id` for this project's profiles/startup settings.

Inspect the SDK's `server.luau` and `packages/moonbase_core/contracts/runtime.luau`
for `server.instances`, `storage`, `redis`, `pubsub`, `subscriptions`, `transfers`,
and `http`. They use callbacks; most hosting operations deliver `HostResult<T>`.
Lifecycle/message callbacks must not yield directly. Enter `task.run` from
`@moonbase/task` at callback boundaries for yielding workflows, using
`@moonbase/hosting` helpers.

Prefer `hosting.startReady`, `transferAndWait`, and `transact` for their readiness,
reconciliation, and revision retries. Reuse an operation ID across uncertain
retries: a timeout does not prove a write/transfer aborted. Validate stored values
into concrete records. Transaction transforms may rerun, so keep them pure and
perform external effects after success. Pub/Sub is a refresh hint; reread
authoritative documents. Preserve intended storage scope and TTL.

To tell a destination why a player came, pass data to the transfer:
`hosting.transferAndWait(players, destination, operation, {via = 'code'})`. The
destination reads `player.arrival` (nil after a launch): a frozen record of
metadata's values, at most 4 KB per player. Keys starting with `@` belong to
libraries (`@moonbase/analytics` carries the visit there). Validate it like any
other input.

## Testing and checking changes

The installed editor discovers `*_test.luau` and `*_test.lua` under project
scripts and `tests/`. Use **Tests** and `@moonbase/test`; these APIs exist only in
a project test run. Tests use saved source. Example `tests/protocol_test.luau`
for the starter protocol:

```luau
--!strict
local test = require('@moonbase/test')
local Protocol = require('@project/shared/Protocol')

test.unit('greeting message names are distinct', function(t)
    t:equal(Protocol.hello, 'hello')
    t:equal(Protocol.welcome, 'welcome')
    t:truthy(Protocol.hello ~= Protocol.welcome)
end)
```

For features, test meaningful rules, invalid input, transitions, and cleanup.
`test.widget` supports mounting widgets, finders, taps, and text entry.
`test.integration` supports game/scene fixtures and rendered behavior. Read
`@moonbase/test` for fixture types. Await asynchronous operations using
`t:await(...)`; forgotten awaits are errors. `t:step` advances game simulation,
`t:pump` advances/pumps UI test time, and `t:wait` waits real time. Pointer
events carry test time, never the host's: `pointerMove`s without a `t:pump`
between them end a drag without velocity, so pump between moves, or use
`t:fling`, to release at speed. Rendered integration cases require a native
host/GPU.

UI modules can require `@moonbase/client` and `@moonbase/game` in any test:
every test VM has stand-ins with the real shapes that record and are driven by
the test. `t:sent()` lists `client.notifyServer` calls (each a list of its
arguments) and `t:deliver(...)` hands a server message to `client.onMessage`
subscribers. `t:appRequests()` lists `game.openLink`, `game.exit` and
`game.minimize` calls; `t:setConnection({status=...})` and `t:setMinimized(...)`
drive `game.connection()`, `game.isMinimized()` and their change callbacks.
`t:loadingScreenHolds()` counts `game.holdLoadingScreen` holds not yet released.
`game.clock()` follows test time (`t:pump`/`t:wait`). Scene and native-host
APIs (`loadScene`, `GameView`, `spawnVisual`, `audio`...) fail in these
stand-ins; run the game with `t:startGame` in `test.integration` for those.
`@moonbase/preferences` is the real module in tests: each case starts on an
empty device, which its `t:startGame` games share.

Test rules through explicit adapters/fixtures where appropriate; mocked rules
tests do not establish that actual hosting, storage, or transfers work. Use
multiple clients in Play for authority/messaging changes. Check console errors,
the network inspector, scene replacement, relevant reconnect behavior, and
Stop/Play cleanup. Compilation alone does not establish runtime behavior.

Typecheck through the editor: `check_scripts` for saved files, `check_script_source`
for code you are about to write. VS Code uses the same SDK definitions through the
luau-lsp extension. For unresolved standard modules, check SDK and
configuration first; open the project in Moonbase rather than inventing stubs.
Avoid broad `any`, `--!nocheck`, or disabled diagnostics to mask side/API errors.

## When a host API is missing

First compose existing APIs or identify the missing host capability. Editing
`.moonbase/sdk` or `.d.luau` declarations is not a fix. If the workspace includes
the Moonbase application repository and the task includes engine work, generated
client bindings are selected in `packages/moonbase_bindings/luau_bindings.yaml`;
engine bindings use `packages/moonbase_runtime/luau_bindings.yaml`. Native APIs
need their implementation and contracts; host injection may also be required.

Update the owning implementation/selection, regenerate with
`sh scripts/luau_codegen.sh`, validate types/runtime behavior, and rebuild the
editor. That script also refreshes the bundled SDK. For changes only to canonical
SDK sources, `python3 apps/moonbase/tool/generate_project_sdk.py` repackages them;
`--check` detects staleness. These commands run in the Moonbase repository, not a
standalone project. Reopen projects in the updated editor to synchronize their
SDK. Keep project-specific guidance below this guide.
