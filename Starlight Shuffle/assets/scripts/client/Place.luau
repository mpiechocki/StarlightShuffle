--!strict
--@client
-- Where this player is and what it is doing, for the HUD: the place (lobby or
-- cycle, from HELLO), their lifetime Starlights, the cycle's current round with
-- its countdown, whether they paused, the last results, the leaderboard and
-- whether a move between places is under way or failed. It routes the current
-- mini-game's messages to its client module (client/Games). A transfer keeps
-- this VM, so `onTransferred` hears it and everything instance-specific resets.
-- Listeners hear every change.
local client = require("@moonbase/client")
local game = require("@moonbase/game")
local engine = require("@moonbase/engine")
local types = require("@moonbase/types")
local Net = require("../shared/Net")
local Games = require("../shared/Games")
local Minigame = require("./Minigame")
local Modules = require("./Games")

local FAILED_FOR = 4 -- seconds a failed move shows

type Fields = {
	place: Net.Place?,
	starlights: number?,
	round: Net.Round?,
	-- game.clock() when the round's phase ends, as received.
	endsAt: number,
	paused: boolean,
	results: Net.Results?,
	board: Net.Board?, boardOpen: boolean,
	moving: boolean, failed: Net.Reason?, failedAt: number,
	connection: string,
	minigame: Minigame.Minigame?, minigameId: string?,
	scene: engine.Scene?,
	listeners: {() -> ()},
	onTransferred: (() -> ())?,
	unsubscribe: (() -> ())?, unwatch: (() -> ())?,
	-- The whole seconds left last told to listeners, so a countdown rebuilds once a second.
	shownSeconds: number,
}
local Place = {}
Place.__index = Place
export type Controller = typeof(setmetatable({} :: Fields, Place))

local function changed(self: Controller)
	for _, listener in table.clone(self.listeners) do listener() end
end

local function closeMinigame(self: Controller)
	local minigame = self.minigame
	self.minigame, self.minigameId = nil, nil
	if minigame and minigame.dispose then
		local ok, err = pcall(minigame.dispose)
		if not ok then print("Mini-game dispose failed: " .. tostring(err)) end
	end
end

-- The client module for [id], made fresh when the cycle moves on to it.
local function openMinigame(self: Controller, id: string?)
	if id == self.minigameId then return end
	closeMinigame(self)
	local info, module = Games.get(id), if id then Modules[id] else nil
	if not info or not module then return end
	local context: Minigame.Context = {
		game = info,
		send = function(...: types.Value)
			if self.minigameId == info.id then client.notifyServer(Net.GAME, info.id, ...) end
		end,
		scene = function(): engine.Scene? return self.scene end,
		refresh = function() changed(self) end,
	}
	local ok, made = pcall(module.new, context)
	if not ok then print(info.id .. " client failed: " .. tostring(made)); return end
	self.minigame, self.minigameId = made, info.id
end

local function reset(self: Controller)
	closeMinigame(self)
	self.place, self.round, self.results, self.board = nil, nil, nil, nil
	self.boardOpen, self.paused, self.moving, self.failed = false, false, false, nil
	self.endsAt, self.shownSeconds = 0, -1
end

function Place.new(): Controller
	local self = setmetatable({
		place = nil, starlights = nil, round = nil, endsAt = 0, paused = false, results = nil,
		board = nil, boardOpen = false, moving = false, failed = nil, failedAt = 0,
		connection = "offline", minigame = nil, minigameId = nil, scene = nil, listeners = {},
		onTransferred = nil, unsubscribe = nil, unwatch = nil, shownSeconds = -1,
	} :: Fields, Place)
	self.unsubscribe = client.onMessage(function(kind: unknown, a: unknown, ...: unknown)
		if kind == Net.HELLO then
			local place = Net.place(select(2, ...))
			if place then self.place = place; changed(self) end
		elseif kind == Net.STARLIGHTS then
			local total = Net.starlights(a)
			if total then self.starlights = total; changed(self) end
		elseif kind == Net.ROUND then
			local round = Net.round(a)
			if not round then return end
			self.round, self.endsAt = round, game.clock() + round.remaining
			if round.phase == "intro" then self.results = nil end
			if round.phase == "waiting" then openMinigame(self, nil) else openMinigame(self, round.game) end
			changed(self)
		elseif kind == Net.PAUSED then
			if type(a) == "boolean" then self.paused = a; changed(self) end
		elseif kind == Net.RESULTS then
			local results = Net.results(a)
			if results then self.results = results; changed(self) end
		elseif kind == Net.LEADERBOARD then
			local board = Net.board(a)
			if board then self.board = board; changed(self) end
		elseif kind == Net.MOVING then
			self.moving, self.failed = true, nil
			changed(self)
		elseif kind == Net.FAILED then
			self.moving, self.failed, self.failedAt = false, Net.reason(a) or "unavailable", game.clock()
			changed(self)
		elseif kind == Net.GAME then
			local minigame = self.minigame
			if a == self.minigameId and minigame and minigame.receive then
				local ok, err = pcall(minigame.receive, ...)
				if not ok then print("Mini-game message failed: " .. tostring(err)) end
			end
		end
	end)
	local function connection(state: game.ConnectionState)
		local status = state.status
		if status == self.connection and status ~= "transferred" then return end
		self.connection = status
		if status == "transferred" then
			-- Another place: its own world, round and leaderboard.
			reset(self)
			if self.onTransferred then self.onTransferred() end
		end
		changed(self)
	end
	self.unwatch = game.onConnectionChanged(connection)
	connection(game.connection())
	return self
end

-- Whether the server is reachable (a transfer counts: it lands connected).
function Place.online(self: Controller): boolean
	return self.connection == "connected" or self.connection == "transferred"
end

-- Seconds left in the cycle's phase.
function Place.remaining(self: Controller): number
	return math.max(0, self.endsAt - game.clock())
end

function Place.listen(self: Controller, listener: () -> ()): () -> ()
	table.insert(self.listeners, listener)
	return function()
		local at = table.find(self.listeners, listener)
		if at then table.remove(self.listeners, at) end
	end
end

-- The scene shown now, for the mini-game's context.
function Place.setScene(self: Controller, scene: engine.Scene?)
	self.scene = scene
end

function Place.start(self: Controller)
	if self.place ~= "lobby" or self.moving then return end
	client.notifyServer(Net.START)
end

function Place.togglePause(self: Controller)
	if self.place ~= "cycle" or self.moving then return end
	client.notifyServer(Net.PAUSE, not self.paused)
end

function Place.openBoard(self: Controller, open: boolean)
	if open and self.place ~= "lobby" then return end
	self.boardOpen = open
	-- A fresh board each time it opens; the panel shows a spinner until it comes.
	if open then self.board = nil; client.notifyServer(Net.LEADERBOARD) end
	changed(self)
end

-- Taps the current mini-game may take.
function Place.tap(self: Controller, x: number, y: number): boolean
	local minigame = self.minigame
	if not minigame or not minigame.tap then return false end
	local ok, taken = pcall(minigame.tap, x, y)
	return ok and taken == true
end

-- The current mini-game's HUD, if it draws one.
function Place.minigameHud(self: Controller): any
	local minigame = self.minigame
	if not minigame or not minigame.hud then return nil end
	local ok, widget = pcall(minigame.hud)
	if not ok then print("Mini-game HUD failed: " .. tostring(widget)); return nil end
	return widget
end

function Place.update(self: Controller, dt: number)
	local minigame = self.minigame
	if minigame and minigame.update then
		local ok, err = pcall(minigame.update, dt)
		if not ok then print("Mini-game update failed: " .. tostring(err)) end
	end
	-- The countdown rebuilds the HUD once a second; a failed move clears itself.
	local seconds = if self.round and self.round.phase ~= "waiting" then math.ceil(self:remaining()) else -1
	local dirty = seconds ~= self.shownSeconds
	self.shownSeconds = seconds
	if self.failed and game.clock() - self.failedAt > FAILED_FOR then
		self.failed = nil
		dirty = true
	end
	if dirty then changed(self) end
end

function Place.dispose(self: Controller)
	if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
	if self.unwatch then self.unwatch(); self.unwatch = nil end
	closeMinigame(self)
	table.clear(self.listeners)
	self.onTransferred = nil
end

return Place
