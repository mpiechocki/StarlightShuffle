--!strict
--@server
-- A mini-game place: one shared/Games mini-game for the group a lobby sent
-- (server/Lobby picks it and names it in the transfer's data). It goes
--
--   intro (its scene loads, everyone lands in it and it is announced, for
--   its `intro` seconds)
--   -> playing (its duration) -> results (what everyone earned)
--
-- and then everyone goes back to the lobby they came from, where the next
-- mini-game counts down (Games.BREAK). The HUD's Pause/Play button (PAUSE)
-- marks a player to sit the next one out: they go back too, but not checked
-- in. Players who arrive while it is on join it; once it is over, arrivals go
-- straight back.
--
-- The group goes straight from the lobby into the mini-game: the first arrival
-- starts its intro (LANDING seconds longer than usual), and the rest of the
-- group lands during it. The mini-game itself is set up once the whole group is here (or
-- when only its own intro is left), so nobody in it counts as a latecomer. When
-- too few are here to start it (a group that never all arrived), everyone goes
-- back to the lobby, still checked in; a mini-game already playing plays on.
-- With nobody here server/Root stops the place after a grace.
--
-- The mini-game named in the transfer wins; without one (or an unknown one),
-- the first in the admins' lineup (server/Lineup) the group can play. The
-- admins here hear what is on whenever it moves on.
local server = require("@moonbase/server")
local types = require("@moonbase/types")
local Task = require("@moonbase/task")
local Net = require("../shared/Net")
local Games = require("../shared/Games")
local Arena = require("./Arena")
local Starlights = require("./Starlights")
local Travel = require("./Travel")
local Minigame = require("./Minigame")
local Modules = require("./Games")

local RESULTS = 7 -- seconds the results show
-- Seconds a group's first intro adds to the mini-game's own: they are sent
-- together but land one by one (and their outfits just after), and all of them
-- should take part from the start.
local LANDING = 4
local RETRY = 5 -- seconds before a failed trip back to the lobby is tried again
local MAX_AWARD = 1000 -- Starlights one award may add

export type Host = {
	arena: Arena.Arena,
	starlights: Starlights.Starlights,
	name: (session: number) -> string?,
	identity: (session: number) -> Net.Identity?,
	-- Tells [player] their new lifetime total.
	total: (player: server.Player, total: number) -> (),
	-- The admins' lineup: the included mini-game ids; reading it again; telling
	-- the admins here what is on.
	lineup: () -> {string},
	refreshLineup: () -> (),
	moved: () -> (),
}
export type Cycle = {
	added: (player: server.Player) -> (),
	removed: (player: server.Player) -> (),
	receive: (player: server.Player, kind: unknown, ...unknown) -> boolean,
	update: (dt: number) -> (),
	-- The mini-game on now (nil before and after it); the lobby picks the next.
	queue: () -> (string?, string?),
	phase: () -> Net.Phase,
	dispose: () -> (),
}

type Member = {
	player: server.Player,
	paused: boolean,
	-- On the way back to a lobby.
	leaving: boolean,
	-- The lobby that sent them, from the transfer's data.
	lobby: string?,
}

local function lobbyOf(player: server.Player): string?
	local arrival = player.arrival
	local id = if arrival then arrival.lobby else nil
	return if type(id) == "string" and #id > 0 and #id <= 128 then id else nil
end

-- The mini-game the lobby sent [player] to play, if it named a known one.
local function gameOf(player: server.Player): Games.Game?
	local arrival = player.arrival
	local id = if arrival then arrival.game else nil
	return if type(id) == "string" then Games.get(id) else nil
end

local Cycle = {}

function Cycle.new(host: Host): Cycle
	local members: {[number]: Member} = {} -- by session id
	local phase: Net.Phase = "waiting"
	local game: Games.Game? = nil
	local running: Minigame.Minigame? = nil
	local round = 0
	local endsAt = 0 -- server clock when the phase ends
	local playEnds = 0 -- server clock when play ends (or would)
	local earned: {[number]: number} = {} -- this mini-game's Starlights by session
	-- A mini-game announced but not yet set up: its group is still landing.
	local setup: Games.Game? = nil
	-- The mini-game was played (or called off): arrivals go back to the lobby.
	local over = false
	-- The lobby that sent the group, told to other places (Travel.cycles).
	local home: string? = nil

	local function present(): {server.Player}
		local out: {server.Player} = {}
		for _, member in members do
			if member.player.isActive and not member.leaving then table.insert(out, member.player) end
		end
		return out
	end

	local function anyone(): boolean
		return #present() > 0
	end

	-- Whether enough players are here to start a mini-game.
	local function enough(): boolean
		return #present() >= Games.MIN_PLAYERS
	end

	local function roundValue(): types.Value
		return Net.roundValue({ phase = phase, game = if game then game.id else nil, round = round,
			remaining = if phase == "waiting" and endsAt == 0 then 0 else endsAt - server.clock(), players = #present() })
	end

	-- Everyone here hears the round; the lobby sees it in this place's metadata
	-- (Travel.cycles), so its players know what is on until the group is back.
	local function broadcast()
		server.notifyPlayers(nil, Net.ROUND, roundValue())
		local left = if phase == "waiting" and endsAt == 0 then 0 else math.max(0, endsAt - server.clock())
		Travel.publish({ phase = phase, game = if game then game.id else "", players = tostring(#present()),
			ends = tostring(math.floor(os.time() + left)), lobby = home or "" })
	end


	-- Calls [name] on the running mini-game; a failure is printed, never fatal to the cycle.
	local function call(name: string, ...: any)
		local minigame = running
		local f = if minigame then (minigame :: any)[name] else nil
		if type(f) ~= "function" then return end
		local ok, err = pcall(f, ...)
		if not ok then print((if game then game.id else "?") .. "." .. name .. " failed: " .. tostring(err)) end
	end

	local finishPlay: () -> ()
	local disband: () -> ()

	local function context(current: Games.Game): Minigame.Context
		return {
			game = current,
			arena = host.arena,
			players = present,
			award = function(player: server.Player, starlights: number)
				if game ~= current or (phase ~= "intro" and phase ~= "playing") then return end
				if type(starlights) ~= "number" or starlights ~= starlights or starlights <= 0 then return end
				if not members[player.session_id] then return end
				local amount = math.min(MAX_AWARD, math.floor(starlights))
				earned[player.session_id] = (earned[player.session_id] or 0) + amount
			end,
			send = function(players: {server.Player}?, ...: types.Value)
				if game ~= current then return end
				server.notifyPlayers(players, Net.GAME, current.id, ...)
			end,
			clock = server.clock,
			remaining = function(): number
				return if phase == "playing" then math.max(0, playEnds - server.clock()) else current.duration
			end,
			startsIn = function(): number
				return if game == current and phase == "intro" then math.max(0, endsAt - server.clock()) else 0
			end,
			identity = function(player: server.Player): Net.Identity?
				return host.identity(player.session_id)
			end,
			finish = function()
				if game == current and phase == "playing" then finishPlay() end
			end,
		}
	end

	-- The next mini-game: load its scene, announce it.
	-- Sets up [current]'s server module, with everyone here taking part.
	local function begin(current: Games.Game)
		setup = nil
		local module = Modules[current.id]
		if module then
			local ok, made = pcall(module.new, context(current))
			if ok then running = made else print(current.id .. ".new failed: " .. tostring(made)) end
		else
			print("No server module for mini-game " .. current.id)
		end
	end

	-- A group of at least Games.MIN_PLAYERS is landing, sent to play [wanted]
	-- (else the first mini-game in the lineup that many can play).
	local function intro(wanted: Games.Game?)
		local nextGame = wanted or Games.pick(0, host.lineup(), math.max(#present(), Games.MIN_PLAYERS))
		game, round = nextGame, round + 1
		table.clear(earned)
		phase, endsAt = "intro", server.clock() + (nextGame.intro or Games.INTRO) + LANDING
		host.arena.load(nextGame.scene)
		running, setup = nil, nil
		-- Announced first, so clients have the mini-game's module ready for
		-- whatever it sends as it starts.
		broadcast()
		host.moved()
		if not enough() then setup = nextGame else begin(nextGame) end
	end

	local function play()
		local current = assert(game)
		if setup then begin(current) end
		phase = "playing"
		endsAt = server.clock() + current.duration
		playEnds = endsAt
		call("start")
		broadcast()
	end

	-- Everyone here back to the lobby, grouped by the lobby they came from:
	-- those who did not pause stay checked in there for the next mini-game.
	local function sendOff()
		local groups: {[string]: {server.Player}} = {}
		local keen: {[string]: {server.Player}} = {}
		for _, member in members do
			if not member.leaving and member.player.isActive then
				member.leaving = true
				local key = member.lobby or ""
				local into = if member.paused then groups else keen
				into[key] = into[key] or {}
				table.insert(into[key], member.player)
			end
		end
		local trips: {{lobby: string, players: {server.Player}, ready: boolean}} = {}
		for lobby, players in groups do table.insert(trips, { lobby = lobby, players = players, ready = false }) end
		for lobby, players in keen do table.insert(trips, { lobby = lobby, players = players, ready = true }) end
		for _, trip in trips do
			local lobby, players = trip.lobby, trip.players
			server.notifyPlayers(players, Net.MOVING)
			Task.run(function()
				local ok, code = Travel.send(players, "lobby", { ready = trip.ready }, if lobby ~= "" then lobby else nil)
				if ok then return end
				print("Back to the lobby failed: " .. tostring(code))
				-- They wait here, told why, and try again soon.
				for _, player in players do
					local member = members[player.session_id]
					if member and player.isActive then
						member.leaving = false
						server.notifyPlayers({player}, Net.FAILED, "unavailable")
					end
				end
				server.after(RETRY, function() if anyone() then sendOff() end end)
			end, function(err: server.RpcError)
				print("Back to the lobby failed: " .. err.message)
			end)
		end
	end

	local function results()
		local current = assert(game)
		call("finish")
		phase, endsAt = "results", server.clock() + RESULTS
		local rows: {Net.Row} = {}
		local awards: {Starlights.Award} = {}
		local bySession: {[number]: server.Player} = {}
		for session, member in members do
			local name = host.name(session) or ("Player " .. member.player.player_id)
			-- Its podium prize (shared/Rewards), if any.
			local amount = earned[session] or 0
			bySession[session] = member.player
			table.insert(rows, { player = member.player.player_id, name = name, starlights = amount })
			if amount > 0 then table.insert(awards, { player = member.player.player_id, name = name, amount = amount }) end
		end
		table.sort(rows, function(a: Net.Row, b: Net.Row): boolean
			if a.starlights ~= b.starlights then return a.starlights > b.starlights end
			return a.name < b.name
		end)
		while #rows > Net.MAX_RESULTS do table.remove(rows) end
		broadcast()
		-- One award per mini-game played here: a retry counts once. Each take is
		-- boosted by its player's booster as the store awards it, and the
		-- results show what was given (what was earned, if the store failed).
		local shown = round
		host.starlights.award(server.context.instance_id .. ":" .. round, awards, function(award: Starlights.Awarded?)
			if award then
				for _, row in rows do row.starlights = award.given[row.player] or row.starlights end
				table.sort(rows, function(a: Net.Row, b: Net.Row): boolean
					if a.starlights ~= b.starlights then return a.starlights > b.starlights end
					return a.name < b.name
				end)
			end
			if round == shown and phase == "results" then
				server.notifyPlayers(nil, Net.RESULTS, Net.resultsValue({ game = current.id, rows = rows }))
			end
			if not award then return end
			for _, player in bySession do
				local total = award.totals[player.player_id]
				if total and player.isActive then host.total(player, total) end
			end
		end)
	end

	finishPlay = function()
		if phase ~= "playing" then return end
		results()
	end

	-- The mini-game is over (or called off): everyone back to the lobby.
	local function close()
		call("dispose")
		running, game, setup, over = nil, nil, nil, true
		phase, endsAt = "waiting", 0
		sendOff()
		broadcast()
		host.moved()
	end

	-- Too few to start the mini-game: everyone back to the lobby, checked in.
	disband = function()
		print("Fewer than " .. Games.MIN_PLAYERS .. " players: back to the lobby")
		close()
	end

	return {
		added = function(player: server.Player)
			members[player.session_id] = { player = player, paused = false, leaving = false, lobby = lobbyOf(player) }
			host.arena.join(player)
			server.notifyPlayers({player}, Net.PAUSED, false)
			if over then
				-- Too late for it: back to the lobby, still checked in.
				sendOff()
			elseif phase == "waiting" then
				-- Straight into the mini-game: its intro starts, and the rest of the group lands during it.
				home = lobbyOf(player)
				local wanted = gameOf(player)
				if not wanted then host.refreshLineup() end
				intro(wanted)
			else
				server.notifyPlayers({player}, Net.ROUND, roundValue())
				-- A group still landing is set up in update, once all here and dressed.
				if not setup and (phase == "intro" or phase == "playing") then call("join", player) end
			end
		end,
		removed = function(player: server.Player)
			if not members[player.session_id] then return end
			members[player.session_id] = nil
			earned[player.session_id] = nil
			host.arena.leave(player)
			if phase == "intro" or phase == "playing" then call("leave", player) end
		end,
		receive = function(player: server.Player, kind: unknown, ...: unknown): boolean
			local member = members[player.session_id]
			if kind == Net.PAUSE then
				local paused = ...
				if member and type(paused) == "boolean" and not member.leaving then
					member.paused = paused
					server.notifyPlayers({player}, Net.PAUSED, paused)
				end
				return true
			end
			if kind == Net.GAME then
				local id = ...
				-- Only the current mini-game hears its own messages, and only during play.
				if member and game and id == game.id and (phase == "intro" or phase == "playing") then
					call("receive", player, select(2, ...))
				end
				return true
			end
			return false
		end,
		update = function(dt: number)
			local now = server.clock()
			if phase == "waiting" then return end
			if phase == "playing" then call("update", dt) end
			-- A group still landing: its mini-game is set up once they are all here
			-- and their outfits known (their LOOK lands just after them), or in
			-- time for its own intro.
			local waiting = setup
			if phase == "intro" and waiting then
				local dressed = enough()
				for _, player in present() do
					local who = host.identity(player.session_id)
					if not who or not who.outfit then dressed = false end
				end
				if dressed or endsAt - now <= (waiting.intro or Games.INTRO) then begin(waiting) end
			end
			if now < endsAt then return end
			if phase == "intro" then
				-- Too few left to start: back to the lobby to check in again.
				if enough() then play() else disband() end
			elseif phase == "playing" then
				finishPlay()
			elseif phase == "results" then
				close()
			end
		end,
		queue = function(): (string?, string?)
			return if phase ~= "waiting" and game then game.id else nil, nil
		end,
		phase = function(): Net.Phase return phase end,
		dispose = function()
			call("dispose")
			running = nil
		end,
	}
end

return table.freeze(Cycle)
