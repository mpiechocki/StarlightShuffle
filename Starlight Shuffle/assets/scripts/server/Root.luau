--!strict
--@server
-- Every server instance runs this root and is one *place*, by its hosting
-- profile (project.json):
--
--   lobby  (the initial profile): server/Lobby. Launches land here, and
--          everyone comes back here between mini-games.
--   cycle: server/Cycle, one mini-game for a group the lobby sent.
--
-- Both run their scenes and everyone's avatar in server/Arena, know who is
-- here from server/People, and keep Starlight balances in server/Starlights.
-- Arrivals hear HELLO (who they are, which place) and their Starlight balance.
-- Every player's shop account (server/Accounts) is read on arrival for what
-- they wear; the lobby also runs the shop, paying in Stars through the
-- platform's economy (@moonbase/economy; a stand-in in editor Play).
-- A place with nobody in it stops itself after a grace (server/Travel).
-- Admins (server/Admins) hear and set the mini-game lineup in either place
-- (server/Lineup). The lobby has chat (server/Chat), moderated through the
-- platform (@moonbase/social); a mini-game place has none open.
local server = require("@moonbase/server")
local scenes = require("@moonbase/scene")
local Social = require("@moonbase/social")
local Economy = require("@moonbase/economy")
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
local ChatRelay = require("./ChatRelay")
local Accounts = require("./Accounts")

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
local lobby: Lobby.Lobby? = nil
local chat: Chat.Chat? = nil
local relay: ChatRelay.Relay? = nil
local accounts: Accounts.Accounts? = nil

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
		local admins = Admins.new(server.startup)
		local shop = Accounts.new({
			send = function(player: types.Player, ...: types.Value) server.notifyPlayers({player}, ...) end,
			clock = server.clock, after = server.after, economy = Economy.new(),
			look = people.setLook, total = total, shop = place == "lobby", admin = admins.is,
			-- The shop's test tools reward through the real award, booster and all.
			award = function(player: types.Player, id: string, amount: number, done: (number?) -> ())
				starlights.award(id, {{ player = player.player_id, name = people.name(player.session_id) or "", amount = amount }},
					function(award: Starlights.Awarded?)
						if not award then done(nil); return end
						local count = award.totals[player.player_id]
						if count and player.isActive then total(player, count) end
						done(award.given[player.player_id] or 0)
					end)
			end,
		})
		accounts = shop
		local mode: Mode
		-- The admins' lineup of mini-games, with what is on now and next.
		local lineup = Lineup.new(admins, function(): (string?, string?)
			if cycle then return cycle.queue() end
			if lobby then return lobby.queue() end
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
			local hub = Lobby.new({ arena = world, starlights = starlights, lineup = lineup.included,
				refreshLineup = function() lineup.refresh() end, moved = lineup.notify })
			lobby = hub
			mode = hub
		end
		-- One chat for a lobby and the mini-games its players are off in
		-- (server/ChatRelay), named by the lobby: here, or the group's.
		local talk: Chat.Chat
		local shared = ChatRelay.new(function(message: Chat.Shared) talk.heard(message) end)
		relay = shared
		talk = Chat.new({
			send = function(to: {types.Player}, ...: types.Value) server.notifyPlayers(to, ...) end,
			clock = server.clock, after = server.after, platform = Social.new(),
			room = function() return { id = server.context.instance_id, name = if place == "cycle" then "Mini-games" else "Lobby" } end,
			share = shared.share,
		})
		chat = talk
		if place == "lobby" then shared.use(server.context.instance_id) end
		local function heard(player: server.Player, kind: unknown, a: unknown): boolean
			if kind ~= Net.SAY and kind ~= Net.TYPING then return false end
			talk.receive(player, kind, a)
			return true
		end
		local idle = Travel.idleStop(EMPTY_GRACE[place], function(): boolean return people.count() == 0 end)
		idle()

		table.insert(cancels, server.onPlayerAdded(function(player: server.Player)
			people.added(player)
			if place == "cycle" then
				-- The group's lobby names the chat (without one, this place's own).
				local arrival = player.arrival
				local from = if arrival then arrival.lobby else nil
				shared.use(if type(from) == "string" and #from > 0 and #from <= 128 then from else server.context.instance_id)
			end
			server.notifyPlayers({player}, Net.HELLO, player.session_id, people.name(player.session_id) or "", place)
			starlights.total(player.player_id, function(count: number?)
				if count and player.isActive then total(player, count) end
			end)
			shop.added(player)
			mode.added(player)
			talk.added(player)
			lineup.added(player)
			idle()
		end))
		table.insert(cancels, server.onPlayerRemoved(function(player: server.Player, _reason: string)
			mode.removed(player)
			shop.removed(player)
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
				or heard(player, kind, a) or shop.receive(player, kind, ...) then return end
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
		lobby = nil
		if chat then chat.dispose(); chat = nil end
		if relay then relay.dispose(); relay = nil end
		if accounts then accounts.dispose(); accounts = nil end
		if arena then arena.dispose(); arena = nil end
	end,
})
