--!strict
--@client
-- What a mini-game's client module (minigames/<id>/Client.luau) gets and
-- gives back. client/Place makes one when the cycle announces the mini-game
-- and disposes it when the next one is announced (or the player leaves the
-- cycle). `hud` is drawn over the game view, under the cycle's own HUD, and
-- drawn again whenever the module calls `context.refresh`.
local engine = require("@moonbase/engine")
local types = require("@moonbase/types")
local w = require("@flutter/widgets")
local Games = require("../shared/Games")

export type Context = {
	game: Games.Game,
	-- To this mini-game's server module, as receive(player, ...).
	send: (...types.Value) -> (),
	-- The mini-game's scene once it shows; nil while it loads.
	scene: () -> engine.Scene?,
	-- Draws `hud` again.
	refresh: () -> (),
}

export type Minigame = {
	-- A message from this mini-game's server module.
	receive: ((...unknown) -> ())?,
	-- Each frame while it runs.
	update: ((dt: number) -> ())?,
	-- Taps on the game view; true takes the tap instead of walking there.
	tap: ((x: number, y: number) -> boolean)?,
	hud: (() -> w.Widget)?,
	dispose: (() -> ())?,
}

export type Module = { new: (context: Context) -> Minigame }

return {}
