--!strict
--@server
-- Every server instance runs this root and is one *place*, by its hosting
-- profile (project.json):
--
--   lobby  (the initial profile): server/Lobby. Launches land here.
--   cycle: server/Cycle, the mini-game cycle.
--
-- Both run their scenes and everyone's avatar in server/Arena, know who is
-- here from server/People, and keep lifetime Starlights in server/Starlights.
-- Arrivals hear HELLO (who they are, which place) and their Starlights total.
-- A place with nobody in it stops itself after a grace (server/Travel).
-- Admins (server/Admins) hear and set the mini-game lineup in either place
-- (server/Lineup).
local server = require("@moonbase/server")
local scenes = require("@moonbase/scene")
local types = require("@moonbase/types")
local Net = require("../shared/Net")
local Arena = require("./Arena")
local People = require("./People")
local Starlights = require("./Starlights")
local Lobby = require("./Lobby")
local Cycle = require("./Cycle")
local Travel = require("./Travel")
local Admins = require("./Admins")
local Lineup = require("./Lineup")

-- What runs this place: server/Lobby or server/Cycle.
type Mode = {
	added: (server.Player) -> (), removed: (server.Player) -> (),
	receive: (server.Player, unknown, ...unknown) -> boolean,
}

local EMPTY_GRACE: {[Net.Place]: number} = { lobby = 300, cycle = 30 } -- seconds

-- Every player's avatar.
--@property
local avatar: scenes.Prefab

local cancels: {() -> ()} = {}
local arena: Arena.Arena? = nil
local cycle: Cycle.Cycle? = nil

return server.defineScript({
	onStart = function()
		local place: Net.Place = if server.context.profile_id == "cycle" then "cycle" else "lobby"
		local people = People.new()
		local starlights = Starlights.new()
		local world = Arena.new({
			send = function(player: types.Player, channel: string, message: types.Value)
				server.notifyPlayers({player}, channel, message)
			end,
			clock = server.clock, tick = server.tick, identity = people.identity,
		}, avatar)
		arena = world
		local function total(player: server.Player, count: number)
			server.notifyPlayers({player}, Net.STARLIGHTS, count)
		end
		local mode: Mode
		-- The admins' lineup of mini-games, with what this cycle plays now and next.
		local lineup = Lineup.new(Admins.new(server.startup), function(): (string?, string?)
			if cycle then return cycle.queue() end
			return nil, nil
		end)
		lineup.refresh()
		if place == "cycle" then
			local running = Cycle.new({ arena = world, starlights = starlights, name = people.name,
				identity = people.identity, total = total, lineup = lineup.included,
				refreshLineup = function() lineup.refresh() end, moved = lineup.notify })
			cycle = running
			mode = running
		else
			mode = Lobby.new({ arena = world, starlights = starlights })
		end
		local idle = Travel.idleStop(EMPTY_GRACE[place], function(): boolean return people.count() == 0 end)
		idle()

		table.insert(cancels, server.onPlayerAdded(function(player: server.Player)
			people.added(player)
			server.notifyPlayers({player}, Net.HELLO, player.session_id, people.name(player.session_id) or "", place)
			starlights.total(player.player_id, function(count: number?)
				if count and player.isActive then total(player, count) end
			end)
			mode.added(player)
			lineup.added(player)
			idle()
		end))
		table.insert(cancels, server.onPlayerRemoved(function(player: server.Player, _reason: string)
			mode.removed(player)
			lineup.removed(player)
			people.removed(player)
			idle()
		end))
		table.insert(cancels, server.onPlayerMetadataChanged(function(player: server.Player, _previous: unknown, _changed: {string})
			people.metadataChanged(player)
		end))
		table.insert(cancels, server.onMessage(function(player: server.Player, kind: unknown, ...: unknown)
			if not player.isActive then return end
			local a = ...
			if people.receive(player, kind, a) or world.receive(player, kind, a) or lineup.receive(player, kind, ...) then return end
			mode.receive(player, kind, ...)
		end))
	end,
	onUpdate = function(dt: number)
		if cycle then cycle.update(dt) end
		if arena then arena.update(dt) end
	end,
	onDestroy = function()
		for _, cancel in cancels do cancel() end
		table.clear(cancels)
		if cycle then cycle.dispose(); cycle = nil end
		if arena then arena.dispose(); arena = nil end
	end,
})
