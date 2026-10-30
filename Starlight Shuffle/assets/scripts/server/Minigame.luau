--!strict
--@server
-- What a mini-game's server module (minigames/<id>/Server.luau) gets from the
-- cycle and gives back. The cycle (server/Cycle) loads the mini-game's scene,
-- places everyone's avatar at its `player-spawn`, then calls `new` while the
-- mini-game is announced, `start` when play begins and `finish` when its time
-- is up (or it called `context.finish`). Players who arrive during the
-- announcement or play are `join`ed; anyone who leaves is `leave`d. After the
-- results, `dispose` (if any) runs and the next mini-game's scene replaces
-- this one, taking every entity in it along.
--
-- Starlights: `context.award` adds to a player's take for this mini-game; the
-- cycle shows everyone's take in the results and adds it to their lifetime
-- total (server/Starlights).
--
-- Messages: `context.send` reaches the clients' module for this mini-game
-- (minigames/<id>/Client.luau) as `receive(...)`; a client's
-- `send(...)` arrives here as `receive(player, ...)`. Validate everything a
-- client sends.
local server = require("@moonbase/server")
local types = require("@moonbase/types")
local Games = require("../shared/Games")
local Net = require("../shared/Net")
local Arena = require("./Arena")

export type Context = {
	game: Games.Game,
	-- The loaded scene and everyone's avatar in it.
	arena: Arena.Arena,
	-- Everyone taking part: everyone in this cycle.
	players: () -> {server.Player},
	award: (player: server.Player, starlights: number) -> (),
	-- To these players (everyone here when nil).
	send: (players: {server.Player}?, ...types.Value) -> (),
	clock: () -> number,
	-- Seconds of play left (the whole duration before play starts).
	remaining: () -> number,
	-- Seconds until play starts (0 once it has).
	startsIn: () -> number,
	-- Who [player] is: their name, outfit and thumbnail (server/People).
	identity: (player: server.Player) -> Net.Identity?,
	-- Ends play now, before the time is up.
	finish: () -> (),
}

export type Minigame = {
	start: (() -> ())?,
	join: ((player: server.Player) -> ())?,
	leave: ((player: server.Player) -> ())?,
	receive: ((player: server.Player, ...unknown) -> ())?,
	-- Each server tick during play.
	update: ((dt: number) -> ())?,
	-- Play is over: award what is still owed.
	finish: (() -> ())?,
	dispose: (() -> ())?,
}

export type Module = { new: (context: Context) -> Minigame }

return {}
