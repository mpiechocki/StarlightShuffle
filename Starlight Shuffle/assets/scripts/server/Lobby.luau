--!strict
--@server
-- A lobby: where launches land and where players come back to after leaving
-- the mini-game cycle. Everyone walks the lobby scene in their own outfit
-- (server/Arena). START (the big button on the wall) sends the player to a
-- cycle with room, the fullest first, starting one when none has. LEADERBOARD
-- answers with the top players and where the asker stands.
local server = require("@moonbase/server")
local Task = require("@moonbase/task")
local Net = require("../shared/Net")
local Arena = require("./Arena")
local Starlights = require("./Starlights")
local Travel = require("./Travel")

local SCENE = "scene:lobby"
local BOARD_COOLDOWN = 2 -- seconds between one player's leaderboard requests
local GATHER = 0.5 -- seconds START waits for others pressing it too

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
	local queue: {server.Player} = {} -- pressed START, not yet sent
	local sending = false
	local flying: {server.Player} = {} -- the group being sent now
	local askedAt: {[number]: number} = {}

	local function failed(players: {server.Player}, code: string?)
		print("Start cycle failed: " .. tostring(code))
		for _, player in players do
			busy[player.session_id] = nil
			if player.isActive then
				server.notifyPlayers({player}, Net.FAILED, if code == "capacity_unavailable" then "full" else "unavailable")
			end
		end
	end

	-- One send at a time, taking everyone who pressed START meanwhile, so
	-- players pressing together share a cycle instead of each starting one.
	local function drain()
		if sending or #queue == 0 then return end
		sending = true
		Task.run(function()
			while #queue > 0 do
				Task.sleep(GATHER)
				local group = queue
				queue, flying = {}, group
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

	local function start(player: server.Player)
		local session = player.session_id
		if busy[session] then
			server.notifyPlayers({player}, Net.FAILED, "busy")
			return
		end
		busy[session] = true
		server.notifyPlayers({player}, Net.MOVING)
		table.insert(queue, player)
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
		end,
		removed = function(player: server.Player)
			host.arena.leave(player)
			busy[player.session_id], askedAt[player.session_id] = nil, nil
		end,
		receive = function(player: server.Player, kind: unknown, ...: unknown): boolean
			if kind == Net.START then start(player); return true end
			if kind == Net.LEADERBOARD then board(player); return true end
			return false
		end,
	}
end

return table.freeze(Lobby)
