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
local Net = require("../shared/Net")

export type Context = {
	game: Games.Game,
	-- To this mini-game's server module, as receive(player, ...).
	send: (...types.Value) -> (),
	-- The mini-game's scene once it shows; nil while it loads.
	scene: () -> engine.Scene?,
	-- Draws `hud` again.
	refresh: () -> (),
	-- The cycle's round now (its phase and seconds left), and whether this
	-- player paused (they leave once this mini-game ends).
	round: () -> Net.Round?,
	remaining: () -> number,
	paused: () -> boolean,
	-- This player's session id once the server said it (HELLO).
	me: () -> number?,
}

-- What the cycle's timer shows (widgets/Hud), the same for every mini-game:
-- the seconds until play starts (`starting`) or left in it, and of how many.
export type Clock = { starting: boolean, seconds: number, total: number }

export type Minigame = {
	-- A message from this mini-game's server module.
	receive: ((...unknown) -> ())?,
	-- Each frame while it runs.
	update: ((dt: number) -> ())?,
	-- Taps on the game view; true takes the tap instead of walking there.
	tap: ((x: number, y: number) -> boolean)?,
	hud: (() -> w.Widget)?,
	-- The mini-game draws its own status, announcement and results: the cycle's
	-- HUD then keeps only your Starlights and the Pause/Play button.
	ownHud: boolean?,
	-- The mini-game's own clock for the cycle's timer, when its play is not
	-- the cycle's phases (a reveal before it, say); nil, or no function, for
	-- the cycle's: its intro, then its playing phase.
	clock: (() -> Clock?)?,
	-- The camera holds the scene's authored view instead of following your
	-- avatar; the mini-game's HUD should then take every touch.
	fixedCamera: boolean?,
	dispose: (() -> ())?,
}

export type Module = { new: (context: Context) -> Minigame }

return {}
