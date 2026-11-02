--!strict
-- A hand-driven host for the lobby chat's tests (server/Chat), after Sky
-- Lounge's FakeHost: a clock moved by the test, its timers, every message
-- sent, and a platform whose answers the test gives. Platform requests wait
-- until answered, unless `answer` is set. The platform keeps chat for
-- experience M.EXPERIENCE (or none, with `keeps` false).
local types = require("@moonbase/types")
local Social = require("@moonbase/social")
local Chat = require("@project/server/Chat")

export type Ask = { player: number, among: {number}, done: (Social.Relations?) -> () }
export type Check = { player: number, text: string, room: Social.Room, id: string, done: (boolean?) -> () }
type Timer = { at: number, callback: () -> (), cancelled: boolean }
export type Fake = {
	host: Chat.Host,
	time: number,
	-- Everything each session received, as {kind, ...values}.
	inboxes: {[number]: {{unknown}}},
	asks: {Ask}, checks: {Check},
	-- When set, relations are answered at once with this.
	answer: ((player: number, among: {number}) -> Social.Relations?)?,
	timers: {Timer},
	advance: (self: Fake, seconds: number) -> (),
	player: (self: Fake, session: number, id: number, metadata: {[string]: unknown}?) -> types.Player,
	-- What [session] received of [kind], oldest first.
	got: (self: Fake, session: number, kind: string) -> {{unknown}},
	clear: (self: Fake) -> (),
}

local M = {}

M.EXPERIENCE = "Shuffle1"

-- Relations from a list of blocked ids.
function M.relations(blocked: {number}?): Social.Relations
	local out: Social.Relations = { blocked = {}, friends = {} }
	for _, id in blocked or {} do out.blocked[id] = true end
	return out
end

function M.new(keeps: boolean?): Fake
	local self = { time = 0, inboxes = {}, asks = {}, checks = {}, answer = nil, timers = {} } :: Fake
	local serial = 0
	local kept = keeps ~= false
	local platform: Social.Social = {
		relations = function(player: number, among: {number}, done: (Social.Relations?) -> ())
			if #among == 0 then done(M.relations()); return end
			local answer = self.answer
			if answer then done(answer(player, among)); return end
			table.insert(self.asks, { player = player, among = table.clone(among), done = done })
		end,
		experience = if kept then M.EXPERIENCE else nil,
		messageId = function(): string?
			if not kept then return nil end
			serial += 1
			return "test_" .. serial
		end,
		moderate = function(player: number, text: string, room: Social.Room, id: string, done: (boolean?) -> ())
			table.insert(self.checks, { player = player, text = text, room = room, id = id, done = done })
		end,
	}
	self.host = {
		send = function(to: {types.Player}, ...: types.Value)
			for _, player in to do
				local inbox = self.inboxes[player.session_id] or {}
				self.inboxes[player.session_id] = inbox
				table.insert(inbox, {...})
			end
		end,
		clock = function(): number return self.time end,
		after = function(seconds: number, callback: () -> ()): () -> ()
			local timer: Timer = { at = self.time + seconds, callback = callback, cancelled = false }
			table.insert(self.timers, timer)
			return function() timer.cancelled = true end
		end,
		platform = platform,
		room = function(): Social.Room return { id = "test-instance", name = "Lobby" } end,
	}
	function self.advance(f: Fake, seconds: number)
		f.time += seconds
		local due: {Timer} = {}
		for i = #f.timers, 1, -1 do
			local timer = f.timers[i]
			if timer.cancelled or timer.at <= f.time then
				table.remove(f.timers, i)
				if not timer.cancelled then table.insert(due, timer) end
			end
		end
		table.sort(due, function(a: Timer, b: Timer): boolean return a.at < b.at end)
		for _, timer in due do timer.callback() end
	end
	function self.player(_: Fake, session: number, id: number, metadata: {[string]: unknown}?): types.Player
		return { session_id = session, player_id = id, metadata = (metadata or {alias = "P" .. id}) :: any, isActive = true }
	end
	function self.got(f: Fake, session: number, kind: string): {{unknown}}
		local out: {{unknown}} = {}
		for _, message in f.inboxes[session] or {} do
			if message[1] == kind then table.insert(out, message) end
		end
		return out
	end
	function self.clear(f: Fake)
		table.clear(f.inboxes)
	end
	return self
end

return table.freeze(M)
