--!strict
--@client
-- The server's clock on this client, for mini-games that time things to it.
-- Pings (a mini-game's SYNC message with game.clock(); the server echoes it with
-- its own time) measure the round trip, and the offset from the fastest one
-- maps server times onto game.clock(). A burst of pings at first, then one
-- now and then. Until the first answer, a snapshot's serverNow seeds it.
local game = require("@moonbase/game")

local BURST_EVERY = 0.25 -- seconds between pings while the count is short
local BURST = 8
local RESYNC = 5 -- seconds between pings after that

type Fields = { offset: number?, best: number, pings: number, pingAt: number, ping: (clientTime: number) -> () }
local ServerClock = {}
ServerClock.__index = ServerClock
export type Clock = typeof(setmetatable({} :: Fields, ServerClock))

-- [ping] sends the mini-game's SYNC with the given client time.
function ServerClock.new(ping: (clientTime: number) -> ()): Clock
	return setmetatable({ offset = nil, best = math.huge, pings = 0, pingAt = -math.huge, ping = ping } :: Fields, ServerClock)
end

-- The server's time now, as best we know it.
function ServerClock.now(self: Clock): number
	return game.clock() + (self.offset or 0)
end

-- A server time on game.clock().
function ServerClock.toLocal(self: Clock, at: number): number
	return at - (self.offset or 0)
end

-- A rough first offset from a snapshot, until the pings answer.
function ServerClock.seed(self: Clock, serverNow: number)
	if not self.offset then self.offset = serverNow - game.clock() end
end

-- An answer to a ping: (the client time we sent, the server's time).
function ServerClock.answer(self: Clock, sent: unknown, server: unknown)
	if type(sent) ~= "number" or type(server) ~= "number" then return end
	local trip = game.clock() - sent
	if trip >= 0 and trip < self.best then
		self.best = trip
		self.offset = server + trip / 2 - game.clock()
	end
end

-- Call every frame: pings when one is due.
function ServerClock.update(self: Clock)
	local clock = game.clock()
	if clock - self.pingAt >= (if self.pings < BURST then BURST_EVERY else RESYNC) then
		self.pingAt = clock
		self.pings += 1
		self.ping(clock)
	end
end

return ServerClock
