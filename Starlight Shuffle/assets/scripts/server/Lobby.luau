--!strict
--@server
-- A lobby: where launches land and where players come back to after leaving
-- the mini-game cycle. Everyone walks the lobby scene in their own outfit
-- (server/Arena). START (tapping the arcade) checks a player in for the next
-- mini-game, or out again; everyone here hears how many are in (READY). Once
-- Games.MIN_PLAYERS are, they all go together to a cycle with room, the
-- fullest first, starting one when none has. Players a cycle sends back for
-- want of company arrive checked in. LEADERBOARD answers with the top players
-- and where the asker stands.
local server = require("@moonbase/server")
local Task = require("@moonbase/task")
local Net = require("../shared/Net")
local Games = require("../shared/Games")
local Arena = require("./Arena")
local Starlights = require("./Starlights")
local Travel = require("./Travel")

local SCENE = "scene:lobby"
local BOARD_COOLDOWN = 2 -- seconds between one player's leaderboard requests
local GATHER = 0.5 -- seconds a full check-in waits for others checking in too

export type Host = {
	arena: Arena.Arena,
	starlights: Starlights.Starlights,
}
export type Lobby = {
	added: (player: server.Player) -> (),
	removed: (player: server.Player) -> (),
	receive: (player: server.Player, kind: unknown, ...unknown) -> boolean,
}

local Lobby = {}

function Lobby.new(host: Host): Lobby
	host.arena.load(SCENE)
	local busy: {[number]: boolean} = {} -- session ids on their way to a cycle
	local queue: {server.Player} = {} -- checked in, in the order they did, not yet sent
	local everyone: {[number]: server.Player} = {} -- here, by session id
	local sending = false
	local flying: {server.Player} = {} -- the group being sent now
	local askedAt: {[number]: number} = {}

	local function indexIn(player: server.Player): number?
		for i, other in queue do
			if other.session_id == player.session_id then return i end
		end
		return nil
	end

	-- Everyone here hears how many are checked in, and whether they are.
	local function tell()
		for _, player in everyone do
			if player.isActive then server.notifyPlayers({player}, Net.READY, #queue, indexIn(player) ~= nil) end
		end
	end

	local function failed(players: {server.Player}, code: string?)
		print("Start cycle failed: " .. tostring(code))
		for _, player in players do
			busy[player.session_id] = nil
			if player.isActive then
				server.notifyPlayers({player}, Net.FAILED, if code == "capacity_unavailable" then "full" else "unavailable")
			end
		end
		tell()
	end

	-- One send at a time, once enough are checked in, taking everyone checked
	-- in by then, so they share a cycle instead of each starting one.
	local function drain()
		if sending or #queue < Games.MIN_PLAYERS then return end
		sending = true
		Task.run(function()
			while #queue >= Games.MIN_PLAYERS do
				Task.sleep(GATHER)
				-- Someone may have checked out meanwhile.
				if #queue < Games.MIN_PLAYERS then break end
				local group = queue
				queue, flying = {}, group
				for _, player in group do
					busy[player.session_id] = true
					server.notifyPlayers({player}, Net.MOVING)
				end
				tell()
				-- The cycle sends them back here when it can.
				local ok, code = Travel.send(group, "cycle", { lobby = server.context.instance_id })
				if ok then
					for _, player in group do busy[player.session_id] = nil end
				else
					failed(group, code)
				end
				flying = {}
			end
			sending = false
		end, function(err: server.RpcError)
			local group = table.clone(flying)
			table.move(queue, 1, #queue, #group + 1, group)
			queue, flying, sending = {}, {}, false
			failed(group, err.code)
		end)
	end

	-- Checks [player] in for the next mini-game ([joining]), or out.
	local function start(player: server.Player, joining: unknown)
		if busy[player.session_id] then
			server.notifyPlayers({player}, Net.FAILED, "busy")
			return
		end
		local at = indexIn(player)
		if joining == true and not at then
			table.insert(queue, player)
		elseif joining == false and at then
			table.remove(queue, at)
		else
			return
		end
		tell()
		drain()
	end

	local function arrived(player: server.Player)
		everyone[player.session_id] = player
		-- Sent back by a cycle short of players: still in for the next one.
		local arrival = player.arrival
		if arrival and arrival.ready == true then table.insert(queue, player) end
		tell()
		drain()
	end

	local function board(player: server.Player)
		local now, last = server.clock(), askedAt[player.session_id]
		if last and now - last < BOARD_COOLDOWN then return end
		askedAt[player.session_id] = now
		host.starlights.board(player.player_id, function(result: Net.Board?)
			if not player.isActive then return end
			server.notifyPlayers({player}, Net.LEADERBOARD,
				Net.boardValue(result or { top = {}, rank = nil, mine = 0 }))
		end)
	end

	return {
		added = function(player: server.Player)
			host.arena.join(player)
			arrived(player)
		end,
		removed = function(player: server.Player)
			host.arena.leave(player)
			busy[player.session_id], askedAt[player.session_id] = nil, nil
			everyone[player.session_id] = nil
			local at = indexIn(player)
			if at then table.remove(queue, at) end
			tell()
		end,
		receive = function(player: server.Player, kind: unknown, ...: unknown): boolean
			if kind == Net.START then start(player, ...); return true end
			if kind == Net.LEADERBOARD then board(player); return true end
			return false
		end,
	}
end

return table.freeze(Lobby)
