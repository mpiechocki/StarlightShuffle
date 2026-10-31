--!strict
--@server
-- Blast Mining on the cycle's server: the round (Round) with the cycle's
-- context (server/Minigame).
local server = require("@moonbase/server")
local Minigame = require("../../server/Minigame")
local Round = require("./Round")

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local round = Round.new({
			players = context.players, award = context.award, send = context.send, clock = context.clock,
			startsIn = context.startsIn, random = function(): number return math.random() end,
			identity = function(player: server.Player): { name: string, outfit: {number}? }?
				local identity = context.identity(player)
				return if identity then { name = identity.name, outfit = identity.outfit } else nil
			end,
		})
		return {
			start = round.start, join = round.join, leave = round.leave, update = round.update, finish = round.finish,
			receive = function(player: server.Player, kind: unknown, a: unknown, b: unknown)
				round.receive(player, kind, a, b)
			end,
		}
	end,
} :: Minigame.Module
