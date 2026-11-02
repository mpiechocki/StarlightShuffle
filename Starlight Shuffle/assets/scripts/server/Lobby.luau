--!strict
--@server
-- A lobby: where launches land and where players come back to after leaving
-- the mini-game cycle. Everyone walks the lobby scene in their own outfit
-- (server/Arena). START (tapping the arcade) checks a player in for the next
-- mini-game, or out again; everyone here hears how many are in (READY). Once
-- Games.MIN_PLAYERS are, they all go together to a cycle with room, the
-- fullest first, starting one when none has. While a cycle is already running
-- (with players and room; the lobby looks every POLL seconds, Travel.cycles),
-- the count does not matter: whoever checks in joins its next mini-game, sent
-- during its break between mini-games so they land before the next one
-- starts. Players a cycle sends back for want of company arrive checked in.
-- LEADERBOARD answers with the top players and where the asker stands.
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
local POLL = 2 -- seconds between looks at the running cycles
-- A break with less than this many seconds left is too late to land in: they
-- go at the next one.
local LANDING = 4
local RUNNING: {[string]: boolean} = { intro = true, playing = true, results = true, ["break"] = true }

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
	-- The running cycle checked-in players join (the fullest with room), as last seen.
	local running: Travel.Cycle? = nil

	local function indexIn(player: server.Player): number?
		for i, other in queue do
			if other.session_id == player.session_id then return i end
		end
		return nil
	end

	-- Everyone here hears how many are checked in, whether they are, and the
	-- mini-game on in a running cycle they would join (false: none, so
	-- Games.MIN_PLAYERS are needed).
	local function tell()
		local cycle = running
		local on: string | boolean = if cycle then cycle.game or "" else false
		for _, player in everyone do
			if player.isActive then server.notifyPlayers({player}, Net.READY, #queue, indexIn(player) ~= nil, on) end
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

	-- Into the running cycle's break: everyone checked in who fits.
	local function join(cycle: Travel.Cycle)
		sending = true
		local group: {server.Player} = {}
		while #queue > 0 and #group < cycle.room do table.insert(group, table.remove(queue, 1) :: server.Player) end
		flying = group
		for _, player in group do
			busy[player.session_id] = true
			server.notifyPlayers({player}, Net.MOVING)
		end
		tell()
		Task.run(function()
			local ok, code = Travel.sendTo(group, cycle.id, { lobby = server.context.instance_id })
			for _, player in group do busy[player.session_id] = nil end
			if not ok then
				-- Still in for the next one: back in line, told why.
				print("Joining the running cycle failed: " .. tostring(code))
				for i, player in group do
					if player.isActive then
						table.insert(queue, i, player)
						server.notifyPlayers({player}, Net.FAILED, if code == "capacity_unavailable" then "full" else "unavailable")
					end
				end
				running = nil
			end
			flying, sending = {}, false
			tell()
		end, function(err: server.RpcError)
			for _, player in group do busy[player.session_id] = nil end
			for i, player in group do if player.isActive then table.insert(queue, i, player) end end
			print("Joining the running cycle failed: " .. err.message)
			flying, sending, running = {}, false, nil
			tell()
		end)
	end

	-- One send at a time, once enough are checked in, taking everyone checked
	-- in by then, so they share a cycle instead of each starting one. With a
	-- cycle running, they wait for its break instead and join that.
	local function drain()
		local cycle = running
		if sending or #queue == 0 then return end
		if cycle then
			if cycle.phase == "break" and cycle.ends - os.time() >= LANDING and cycle.room > 0 then join(cycle) end
			return
		end
		if #queue < Games.MIN_PLAYERS then return end
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

	-- Looks at the running cycles every POLL seconds while anyone is here.
	local function watch()
		Task.run(function()
			while true do
				Task.sleep(POLL)
				if next(everyone) ~= nil then
					local best: Travel.Cycle? = nil
					for _, cycle in Travel.cycles() do
						if RUNNING[cycle.phase] and cycle.players > 0 and cycle.room > 0
							and (not best or cycle.players > best.players) then best = cycle end
					end
					local before = running
					running = best
					local changed = (before == nil) ~= (best == nil)
						or (before and best and (before.id ~= best.id or before.game ~= best.game)) or false
					if changed then tell() end
					drain()
				end
			end
		end, function(err: server.RpcError)
			print("Watching the cycles stopped: " .. err.message)
		end)
	end
	watch()

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
