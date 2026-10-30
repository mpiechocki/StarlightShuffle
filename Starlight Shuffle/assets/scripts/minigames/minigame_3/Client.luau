--!strict
--@client
-- Mini-game 3's HUD and effects, on each player's client (see client/Minigame
-- for the context and callbacks). Blank for now: the cycle's HUD shows its
-- title and time left, and avatars walk the minigame_3 scene.
local Minigame = require("../../client/Minigame")

return {
	new = function(_context: Minigame.Context): Minigame.Minigame
		return {
			receive = function(...: unknown) end,
		}
	end,
} :: Minigame.Module
