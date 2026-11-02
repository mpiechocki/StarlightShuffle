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
-- (server/Lineup). The lobby has chat (server/Chat), moderated through the
-- platform (@moonbase/social); a cycle has it too, open only during its
-- breaks in the lobby scene.
local server = require("@moonbase/server")
local scenes = require("@moonbase/scene")
local Social = require("@moonbase/social")
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
local Chat = require("./Chat")

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
local chat: Chat.Chat? = nil

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
		local talk = Chat.new({
			send = function(to: {types.Player}, ...: types.Value) server.notifyPlayers(to, ...) end,
			clock = server.clock, after = server.after, platform = Social.new(),
			room = function() return { id = server.context.instance_id, name = if place == "cycle" then "Mini-games" else "Lobby" } end,
		})
		chat = talk
		-- Whether chat is open here: always in the lobby, during a cycle's breaks.
		local function chatting(): boolean
			local running = cycle
			return place == "lobby" or (running ~= nil and running.phase() == "break")
		end
		-- Chat outside a break is dropped, but a typist may always stop typing.
		local function heard(player: server.Player, kind: unknown, a: unknown): boolean
			if kind ~= Net.SAY and kind ~= Net.TYPING then return false end
			if chatting() or (kind == Net.TYPING and a == false) then talk.receive(player, kind, a) end
			return true
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
			talk.added(player)
			lineup.added(player)
			idle()
		end))
		table.insert(cancels, server.onPlayerRemoved(function(player: server.Player, _reason: string)
			mode.removed(player)
			talk.removed(player)
			lineup.removed(player)
			people.removed(player)
			idle()
		end))
		table.insert(cancels, server.onPlayerMetadataChanged(function(player: server.Player, _previous: unknown, changed: {string})
			people.metadataChanged(player)
			talk.metadataChanged(player, changed)
		end))
		table.insert(cancels, server.onMessage(function(player: server.Player, kind: unknown, ...: unknown)
			if not player.isActive then return end
			local a = ...
			if people.receive(player, kind, a) or world.receive(player, kind, a) or lineup.receive(player, kind, ...)
				or heard(player, kind, a) then return end
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
		if chat then chat.dispose(); chat = nil end
		if arena then arena.dispose(); arena = nil end
	end,
})
