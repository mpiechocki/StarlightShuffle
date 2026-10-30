--!strict
--@server
-- Mini-game 1's rules, on the cycle's server (see server/Minigame for what the
-- context offers and when each callback runs). Blank for now: everyone walks
-- around the minigame_1 scene until the time is up, and each player who is
-- still here at the end earns a Starlight for taking part.
local server = require("@moonbase/server")
local Minigame = require("../../server/Minigame")

local TAKING_PART = 1 -- Starlights for playing to the end

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		return {
			finish = function()
				for _, player in context.players() do
					context.award(player, TAKING_PART)
				end
			end,
			receive = function(_player: server.Player, ...: unknown) end,
		}
	end,
} :: Minigame.Module
