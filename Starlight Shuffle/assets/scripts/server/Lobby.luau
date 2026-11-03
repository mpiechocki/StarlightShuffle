--!strict
--@server
-- The lobby: where launches land and where everyone comes back to between
-- mini-games. Everyone walks the lobby scene in their own outfit
-- (server/Arena). START (tapping the arcade) checks a player in for the next
-- mini-game, or out again; everyone here hears how many are in (READY) and,
-- as ROUND, the countdown to the next mini-game while one runs.
--
-- The lobby picks the mini-games (the admins' lineup, in order: shared/Games)
-- and sends everyone checked in to play one together, in a place of its own
-- (server/Cycle), which sends them all back here when it ends, still checked
-- in unless they paused. Their return starts a Games.BREAK countdown here,
-- the next mini-game named; whoever is checked in when it ends goes, if
-- Games.MIN_PLAYERS are. With no mini-game on or counting down, the first
-- Games.MIN_PLAYERS to check in go at once. While a group sent from here is
-- still playing (its place's metadata, Travel.cycles, looked at every POLL
-- seconds), check-ins wait for it to come back and go with it.
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
local POLL = 2 -- seconds between looks at the mini-games sent from here
-- Seconds past its published end a mini-game place is no longer waited for.
local STALE = 15
local PLAYING: {[string]: boolean} = { intro = true, playing = true, results = true }

export type Host = {
	arena: Arena.Arena,
	starlights: Starlights.Starlights,
	-- The admins' lineup: the included mini-game ids; reading it again; telling
	-- the admins here what is on.
	lineup: () -> {string},
	refreshLineup: () -> (),
	moved: () -> (),
}
export type Lobby = {
	added: (player: server.Player) -> (),
	removed: (player: server.Player) -> (),
	receive: (player: server.Player, kind: unknown, ...unknown) -> boolean,
	-- The mini-game a group from here is playing, and the one coming next.
	queue: () -> (string?, string?),
}

local Lobby = {}

function Lobby.new(host: Host): Lobby
	host.arena.load(SCENE)
	local busy: {[number]: boolean} = {} -- session ids on their way to a mini-game
	local queue: {server.Player} = {} -- checked in, in the order they did, not yet sent
	local everyone: {[number]: server.Player} = {} -- here, by session id
	local sending = false
	local flying: {server.Player} = {} -- the group being sent now
	local askedAt: {[number]: number} = {}
	-- A mini-game a group from here is playing, as last seen.
	local away: Travel.Cycle? = nil
	-- The index in Games.list of the last mini-game sent from here.
	local index = 0
	-- The countdown to the next mini-game: what it is, its index, when it ends
	-- (server clock); and which countdown is the latest.
	local coming: { game: Games.Game, index: number, endsAt: number }? = nil
	local countdowns = 0

	local function indexIn(player: server.Player): number?
		for i, other in queue do
			if other.session_id == player.session_id then return i end
		end
		return nil
	end

	-- Everyone here hears how many are checked in, whether they are, and the
	-- mini-game a group from here is playing (false: none); and the countdown.
	local function tell()
		local playing = away
		local on: string | boolean = if playing then playing.game or "" else false
		local countdown = coming
		local round = if countdown
			then Net.roundValue({ phase = "break", game = countdown.game.id, round = 0,
				remaining = math.max(0, countdown.endsAt - server.clock()), players = #queue })
			else Net.roundValue({ phase = "waiting", round = 0, remaining = 0, players = #queue })
		for _, player in everyone do
			if player.isActive then
				server.notifyPlayers({player}, Net.READY, #queue, indexIn(player) ~= nil, on)
				server.notifyPlayers({player}, Net.ROUND, round)
			end
		end
	end

	-- The mini-game after the last one, for [players], and its index.
	local function pick(players: number): (Games.Game, number)
		return Games.pick(index, host.lineup(), math.max(players, Games.MIN_PLAYERS))
	end

	local function failed(players: {server.Player}, code: string?)
		print("Start mini-game failed: " .. tostring(code))
		for _, player in players do
			busy[player.session_id] = nil
			if player.isActive then
				server.notifyPlayers({player}, Net.FAILED, if code == "capacity_unavailable" then "full" else "unavailable")
			end
		end
		tell()
	end

	-- Everyone checked in, together, to play [game] (at [at] in Games.list).
	local function send(game: Games.Game, at: number)
		local group = queue
		queue, flying, sending = {}, group, true
		index = at
		for _, player in group do
			busy[player.session_id] = true
			server.notifyPlayers({player}, Net.MOVING)
		end
		tell()
		Task.run(function()
			-- The mini-game sends them back here when it ends.
			local ok, code = Travel.start(group, "cycle", { lobby = server.context.instance_id, game = game.id })
			if ok then
				for _, player in group do busy[player.session_id] = nil end
			else
				failed(group, code)
			end
			flying, sending = {}, false
			host.moved()
		end, function(err: server.RpcError)
			local lost = flying
			flying, sending = {}, false
			failed(lost, err.code)
		end)
	end

	-- With nothing on or counting down, the first Games.MIN_PLAYERS checked in
	-- go at once, with everyone checked in by then.
	local function drain()
		if sending or coming or away or #queue < Games.MIN_PLAYERS then return end
		sending = true
		Task.run(function()
			Task.sleep(GATHER)
			sending = false
			-- Someone may have checked out, or a countdown begun, meanwhile.
			if coming or away or #queue < Games.MIN_PLAYERS then return end
			send(pick(#queue))
		end, function(err: server.RpcError)
			sending = false
			print("Starting a mini-game failed: " .. err.message)
		end)
	end

	-- A group is back: the next mini-game counts down, named, for Games.BREAK
	-- seconds; then everyone checked in goes, if enough are.
	local function countdown()
		if coming or sending then return end
		host.refreshLineup()
		local game, at = pick(#queue)
		coming = { game = game, index = at, endsAt = server.clock() + Games.BREAK }
		countdowns += 1
		local mine = countdowns
		tell()
		host.moved()
		server.after(Games.BREAK, function()
			local ended = coming
			if mine ~= countdowns or not ended then return end
			coming = nil
			if #queue >= Games.MIN_PLAYERS and not sending then
				send(ended.game, ended.index)
			else
				tell()
				host.moved()
			end
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
		-- Back from a mini-game: still in for the next one, unless they paused;
		-- the next one counts down.
		local arrival = player.arrival
		if arrival and arrival.ready == true then
			table.insert(queue, player)
			countdown()
		end
		tell()
		drain()
	end

	-- Looks at the mini-games sent from here every POLL seconds while anyone is here.
	local function watch()
		Task.run(function()
			while true do
				Task.sleep(POLL)
				if next(everyone) ~= nil then
					local found: Travel.Cycle? = nil
					local now = os.time()
					for _, cycle in Travel.cycles() do
						if cycle.lobby == server.context.instance_id and PLAYING[cycle.phase] and cycle.players > 0
							and now <= cycle.ends + STALE and (not found or cycle.players > found.players) then found = cycle end
					end
					local before = away
					away = found
					local changed = (before == nil) ~= (found == nil)
						or (before and found and (before.id ~= found.id or before.game ~= found.game)) or false
					if changed then tell(); host.moved() end
					drain()
				end
			end
		end, function(err: server.RpcError)
			print("Watching the mini-games stopped: " .. err.message)
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
		queue = function(): (string?, string?)
			local playing, countdown = away, coming
			local current = if playing then playing.game else nil
			if countdown then return current, countdown.game.id end
			return current, (pick(#queue)).id
		end,
	}
end

return table.freeze(Lobby)
