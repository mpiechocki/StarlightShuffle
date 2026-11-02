--!strict
--@server
-- A mini-game cycle: shared/Games played one after another, looping, by
-- everyone in this place. Each mini-game goes
--
--   intro (its scene loads, everyone lands in it and it is announced, for
--   its `intro` seconds)
--   -> playing (its duration) -> results (what everyone earned)
--
-- and then the next one starts. Players who arrive join the mini-game under
-- way, unless it is already showing results. The HUD's Pause/Play button
-- (PAUSE) marks a player to leave: when the current mini-game's results end,
-- they go back to the lobby they came from (or any lobby with room). With
-- nobody here the cycle waits, and server/Root stops it after a grace.
--
-- Only the mini-games in the admins' lineup (server/Lineup) are played; the
-- cycle reads it again while gathering and during each results, and tells
-- the admins here whenever it moves on.
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
-- Seconds an empty cycle waits after its first arrival before announcing a
-- mini-game, so a group sent together (who land one by one) all take part.
local GATHER = 3
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
	-- The mini-game on now (nil while waiting) and the one that would follow it.
	queue: () -> (string?, string?),
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

local Cycle = {}

function Cycle.new(host: Host): Cycle
	local members: {[number]: Member} = {} -- by session id
	local phase: Net.Phase = "waiting"
	local index = 0 -- of the current mini-game in Games.list
	local game: Games.Game? = nil
	local running: Minigame.Minigame? = nil
	local round = 0
	local endsAt = 0 -- server clock when the phase ends
	local playEnds = 0 -- server clock when play ends (or would)
	local earned: {[number]: number} = {} -- this mini-game's Starlights by session
	local loaded: string? = nil -- a scene loaded ahead of its intro, while gathering

	local function roundValue(): types.Value
		return Net.roundValue({ phase = phase, game = if game then game.id else nil, round = round,
			remaining = if phase == "waiting" and endsAt == 0 then 0 else endsAt - server.clock() })
	end

	local function broadcast()
		server.notifyPlayers(nil, Net.ROUND, roundValue())
	end

	local function present(): {server.Player}
		local out: {server.Player} = {}
		for _, member in members do
			if member.player.isActive and not member.leaving then table.insert(out, member.player) end
		end
		return out
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
	local function intro()
		-- The next mini-game this many players can play (a mini-game may need
		-- more than are here: it is skipped this time round).
		local nextGame, nextIndex = Games.pick(index, host.lineup(), #present())
		index, game, round = nextIndex, nextGame, round + 1
		table.clear(earned)
		phase, endsAt = "intro", server.clock() + (nextGame.intro or Games.INTRO)
		if loaded ~= nextGame.scene then host.arena.load(nextGame.scene) end
		loaded = nil -- the next intro loads afresh: this mini-game will have changed it
		running = nil
		-- Announced first, so clients have the mini-game's module ready for
		-- whatever it sends as it starts.
		broadcast()
		host.moved()
		local module = Modules[nextGame.id]
		if module then
			local ok, made = pcall(module.new, context(nextGame))
			if ok then running = made else print(nextGame.id .. ".new failed: " .. tostring(made)) end
		else
			print("No server module for mini-game " .. nextGame.id)
		end
	end

	local function play()
		local current = assert(game)
		phase = "playing"
		endsAt = server.clock() + current.duration
		playEnds = endsAt
		call("start")
		broadcast()
	end

	-- Back to a lobby for everyone who paused, grouped by the lobby they came from.
	local function sendOff()
		local groups: {[string]: {server.Player}} = {}
		for _, member in members do
			if member.paused and not member.leaving and member.player.isActive then
				member.leaving = true
				local key = member.lobby or ""
				groups[key] = groups[key] or {}
				table.insert(groups[key], member.player)
			end
		end
		for lobby, players in groups do
			server.notifyPlayers(players, Net.MOVING)
			Task.run(function()
				local ok, code = Travel.send(players, "lobby", nil, if lobby ~= "" then lobby else nil)
				if ok then return end
				print("Back to the lobby failed: " .. tostring(code))
				-- They stay for the next mini-game; their button shows Play again.
				for _, player in players do
					local member = members[player.session_id]
					if member and player.isActive then
						member.leaving, member.paused = false, false
						server.notifyPlayers({player}, Net.FAILED, "unavailable")
						server.notifyPlayers({player}, Net.PAUSED, false)
					end
				end
			end, function(err: server.RpcError)
				print("Back to the lobby failed: " .. err.message)
			end)
		end
	end

	local function results()
		local current = assert(game)
		call("finish")
		phase, endsAt = "results", server.clock() + RESULTS
		host.refreshLineup()
		local rows: {Net.Row} = {}
		local awards: {Starlights.Award} = {}
		local bySession: {[number]: server.Player} = {}
		for session, member in members do
			local name = host.name(session) or ("Player " .. member.player.player_id)
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
		server.notifyPlayers(nil, Net.RESULTS, Net.resultsValue({ game = current.id, rows = rows }))
		-- One award per mini-game played here: a retry counts once.
		host.starlights.award(server.context.instance_id .. ":" .. round, awards, function(totals: {[number]: number}?)
			if not totals then return end
			for _, player in bySession do
				local total = totals[player.player_id]
				if total and player.isActive then host.total(player, total) end
			end
		end)
	end

	finishPlay = function()
		if phase ~= "playing" then return end
		results()
	end

	local function wait()
		call("dispose")
		running, game = nil, nil
		phase, endsAt = "waiting", 0
		broadcast()
		host.moved()
	end

	local function anyone(): boolean
		return #present() > 0
	end

	return {
		added = function(player: server.Player)
			members[player.session_id] = { player = player, paused = false, leaving = false, lobby = lobbyOf(player) }
			host.arena.join(player)
			server.notifyPlayers({player}, Net.PAUSED, false)
			if phase == "waiting" then
				if endsAt == 0 then
					-- Gather: show the coming mini-game's scene while the rest arrive.
					endsAt = server.clock() + GATHER
					-- (Everyone the gather brings counts; a game too big for them is
					-- skipped at the intro, which then loads its own scene.)
					host.refreshLineup()
					local coming = Games.pick(index, host.lineup(), #present())
					host.arena.load(coming.scene)
					loaded = coming.scene
				end
				server.notifyPlayers({player}, Net.ROUND, roundValue())
			else
				server.notifyPlayers({player}, Net.ROUND, roundValue())
				if phase == "intro" or phase == "playing" then call("join", player) end
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
			if phase == "waiting" then
				if endsAt > 0 and now >= endsAt then
					if anyone() then intro() else endsAt = 0 end
				end
				return
			end
			if phase == "playing" then call("update", dt) end
			if now < endsAt then return end
			if phase == "intro" then
				if anyone() then play() else wait() end
			elseif phase == "playing" then
				finishPlay()
			elseif phase == "results" then
				sendOff()
				call("dispose")
				running = nil
				if anyone() then intro() else wait() end
			end
		end,
		queue = function(): (string?, string?)
			local current = if phase ~= "waiting" and game then game.id else nil
			local upNext = Games.pick(index, host.lineup(), math.max(1, #present()))
			return current, upNext.id
		end,
		dispose = function()
			call("dispose")
			running = nil
		end,
	}
end

return table.freeze(Cycle)
