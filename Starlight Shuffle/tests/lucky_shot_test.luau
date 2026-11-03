--!strict
-- Lucky Shot's field and crowd (Rules, Crowd) and its authoritative round
-- (Round) through a fake cycle context with a clock the test moves: shared
-- claims, the reload, storms below zero, deadlines, duplicates and forged
-- input, reconnection, and the standings.
local test = require("@moonbase/test")
local Rules = require("@project/minigames/lucky_shot/Rules")
local Round = require("@project/minigames/lucky_shot/Round")
local Crowd = require("@project/minigames/lucky_shot/Crowd")

local C = Rules.CONFIG

type Player = { session_id: number, player_id: number, isActive: boolean }
type Sent = { to: {Player}?, kind: string, args: {any} }

local function seeded(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local function round(count: number, seed: number?)
	local players: {Player} = {}
	for i = 1, count do players[i] = { session_id = 10 + i, player_id = 100 + i, isActive = true } end
	local now = 1000
	local sent: {Sent} = {}
	local awards: {[number]: number} = {}
	local game = Round.new({
		players = function() return players :: any end,
		award = function(player: any, n: number) awards[player.player_id] = (awards[player.player_id] or 0) + n end,
		send = function(to: any, kind: any, ...: any) table.insert(sent, { to = to, kind = kind, args = {...} }) end,
		clock = function() return now end,
		startsIn = function() return C.PREPARATION end,
		identity = function(player: any) return { name = "P" .. player.player_id, outfit = nil } end,
		random = seeded(seed or 11),
	})
	local fake = { players = players, game = game, sent = sent, awards = awards }
	function fake.at(t: number) now = t end
	function fake.now(): number return now end
	function fake.last(kind: string, player: Player?): {any}?
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.kind == kind and (s.to == nil or (player ~= nil and table.find(s.to :: {Player}, player) ~= nil)) then return s.args end
		end
		return nil
	end
	function fake.clouds(): {Rules.Cloud}
		local out: {Rules.Cloud} = {}
		for _, s in sent do
			if s.kind == Rules.SPAWN then for _, c in assert(Rules.clouds(s.args[1])) do table.insert(out, c) end end
		end
		return out
	end
	function fake.shots(): {Rules.Shot}
		local out: {Rules.Shot} = {}
		for _, s in sent do if s.kind == Rules.SHOT then table.insert(out, assert(Rules.shot(s.args[1]))) end end
		return out
	end
	function fake.start()
		now = 1000 + C.PREPARATION
		game.start()
		game.update(0)
	end
	function fake.run(t: number)
		while now < t do
			now = math.min(t, now + 1 / 30)
			game.update(1 / 30)
		end
	end
	-- The first cloud showing now, of [kind] if given.
	function fake.live(kind: string?): Rules.Cloud?
		for _, c in fake.clouds() do
			if c.spawnAt <= now and c.expiresAt > now and (kind == nil or c.kind == kind) then
				local taken = false
				for _, shot in fake.shots() do if shot.cloud == c.id and shot.claimed then taken = true end end
				if not taken then return c end
			end
		end
		return nil
	end
	return fake
end

test.unit("the field's pace follows the roster, once", function(t)
	t:equal(Rules.cap(1), 6)
	t:equal(Rules.cap(4), 6)
	t:equal(Rules.cap(12), 8)
	t:equal(Rules.cap(24), 10)
	t:equal(Rules.cap(64), 10)
	t:equal(Rules.interval(4, 0), 0.34)
	t:truthy(math.abs(Rules.interval(16, 1) - 0.53 / 2) < 1e-9)
	t:equal(Rules.interval(400, 0), 0.2, "never faster than 200 ms")
end)

test.unit("clouds keep to the cloud zone, live 1.0 to 1.95 s and get shorter", function(t)
	local random = seeded(5)
	local kinds: {[string]: number} = { white = 0, gold = 0, storm = 0 }
	for i = 1, 600 do
		local elapsed = (i % 45)
		local cloud = assert(Rules.cloud(i, 100, elapsed, {}, random))
		kinds[cloud.kind] += 1
		local life = cloud.expiresAt - cloud.spawnAt
		t:truthy(life >= C.LIFE_MIN - C.LIFE_CUT * elapsed / C.DURATION - 1e-9 and life <= C.LIFE_MAX + 1e-9)
		for _, f in { 0, 0.5, 1 } do
			local x, y = Rules.position(cloud, cloud.spawnAt + f * life)
			t:truthy(x >= C.CLOUD_X[1] - 1e-9 and x <= C.CLOUD_X[2] + 1e-9, "x " .. x)
			t:truthy(y >= C.CLOUD_Y[1] - C.BOB - 1e-9 and y <= C.CLOUD_Y[2] + 1e-9)
		end
		t:truthy(math.abs(cloud.drift) >= C.DRIFT_MIN - 1e-9 and math.abs(cloud.drift) <= C.DRIFT_MAX + 1e-9)
		t:truthy(cloud.size >= C.SIZE_MIN - 1e-9 and cloud.size <= C.SIZE_MAX + 1e-9)
	end
	t:truthy(kinds.white > kinds.gold and kinds.gold > kinds.storm * 0.8 and kinds.storm > 0)
end)

test.unit("everyone stands in the crowd zone, the local player in front, at every roster size", function(t)
	for _, competitors in { 1, 2, 4, 12, 24, 64 } do
		local spots = Crowd.layout(competitors - 1)
		t:equal(#spots, competitors - 1)
		local seen: {[string]: boolean} = {}
		for _, spot in spots do
			-- Heads stay below the sky playfield (the crowd zone is the lower 42%).
			t:truthy(spot.bottom + spot.height <= 42, competitors .. " players: a head above the crowd zone")
			t:truthy(spot.height < Crowd.LOCAL.height, "rivals are smaller")
			t:truthy(spot.x >= 0 and spot.x <= 100)
			t:truthy(spot.opacity >= 0.75 and spot.opacity <= 1)
			local key = spot.x .. ":" .. spot.bottom
			t:truthy(not seen[key], "nobody stands exactly on someone else")
			seen[key] = true
		end
		-- The same roster always gets the same spots.
		local again = Crowd.layout(competitors - 1)
		for i, spot in spots do t:equal(again[i].x, spot.x) end
	end
	t:truthy(Crowd.LOCAL.bottom + Crowd.LOCAL.height <= 42)
end)

test.unit("one cloud, two shooters: exactly one claims it, both reload", function(t)
	local fake = round(2)
	local a, b = fake.players[1], fake.players[2]
	fake.start()
	fake.run(fake.now() + 0.3)
	local cloud = assert(fake.live())
	fake.game.receive(a :: any, Rules.SHOOT, 1, cloud.id, fake.now())
	fake.game.receive(b :: any, Rules.SHOOT, 1, cloud.id, fake.now())
	local shots = fake.shots()
	t:equal(#shots, 2)
	t:truthy(shots[1].claimed and not shots[2].claimed)
	t:equal(shots[2].reason, "claimed")
	t:equal(shots[2].delta, 0)
	t:truthy(shots[2].reloadUntil > fake.now(), "the race still costs a reload")
	t:truthy(shots[1].event ~= shots[2].event)
end)

test.unit("the reload: taps inside it cost nothing, a resend never costs twice", function(t)
	local fake = round(1)
	local a = fake.players[1]
	fake.start()
	fake.run(fake.now() + 0.3)
	local first = assert(fake.live())
	fake.game.receive(a :: any, Rules.SHOOT, 1, first.id, fake.now())
	local reload = fake.shots()[1].reloadUntil
	-- The same sequence again: nothing at all.
	local before = #fake.sent
	fake.game.receive(a :: any, Rules.SHOOT, 1, first.id, fake.now())
	t:equal(#fake.sent, before)
	-- Inside the reload: refused, and the reload is unchanged.
	fake.at(fake.now() + 0.4)
	local other = fake.live()
	if other then
		fake.game.receive(a :: any, Rules.SHOOT, 2, other.id, fake.now())
		t:equal((assert(fake.last(Rules.REJECT, a)))[1], 2)
	end
	-- After it: fine.
	fake.run(reload + 0.05)
	local next = fake.live()
	if next then
		fake.game.receive(a :: any, Rules.SHOOT, 3, next.id, fake.now())
		t:equal(#fake.shots(), 2)
	end
end)

test.unit("storms go below zero; gold is two; made-up clouds and stale shots do nothing", function(t)
	local fake = round(1, 3)
	local a = fake.players[1]
	fake.start()
	local sequence = 0
	local storm: Rules.Cloud? = nil
	while not storm and fake.now() < 1000 + C.PREPARATION + 30 do
		fake.run(fake.now() + 0.1)
		storm = fake.live("storm")
	end
	local s = assert(storm)
	sequence += 1
	fake.game.receive(a :: any, Rules.SHOOT, sequence, s.id, fake.now())
	local shot = fake.shots()[#fake.shots()]
	t:truthy(shot.claimed)
	t:equal(shot.delta, -1)
	t:equal(shot.total, -1, "below zero")
	-- A cloud nobody announced.
	fake.run(fake.now() + 1)
	sequence += 1
	fake.game.receive(a :: any, Rules.SHOOT, sequence, 999999, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, a)))[1], sequence)
	-- A cloud already gone: no score, though it costs the reload.
	local gone = fake.clouds()[1]
	sequence += 1
	fake.game.receive(a :: any, Rules.SHOOT, sequence, gone.id, fake.now())
	local late = fake.shots()[#fake.shots()]
	t:truthy(not late.claimed)
	t:truthy(late.reason == "expired" or late.reason == "claimed", "no score for a cloud that is gone")
	-- Junk and score claims are ignored.
	local before = #fake.sent
	fake.game.receive(a :: any, "score", 50)
	fake.game.receive(a :: any, Rules.SHOOT, "x", 1, 1)
	fake.game.receive({ session_id = 9, player_id = 9, isActive = true } :: any, Rules.SHOOT, 99, 1, fake.now())
	t:equal(#fake.sent, before)
end)

test.unit("nothing counts before the start or at the deadline; claimed times are bounded", function(t)
	local fake = round(1)
	local a = fake.players[1]
	fake.at(1005)
	fake.game.receive(a :: any, Rules.SHOOT, 1, 1, 1005)
	t:equal((assert(fake.last(Rules.REJECT, a)))[1], 1)
	fake.start()
	fake.run(fake.now() + 0.3)
	local cloud = assert(fake.live())
	-- A tap claimed 5 s ago counts as 150 ms ago.
	fake.game.receive(a :: any, Rules.SHOOT, 2, cloud.id, fake.now() - 5)
	t:equal(fake.shots()[1].at, Rules.ms(fake.now() - C.MAX_COMPENSATION))
	local endsAt = 1000 + C.PREPARATION + C.DURATION
	fake.run(endsAt)
	fake.game.receive(a :: any, Rules.SHOOT, 3, cloud.id, endsAt)
	t:equal((assert(fake.last(Rules.REJECT, a)))[1], 3, "eventTime < endsAt")
	-- No cloud is scheduled past the end.
	for _, c in fake.clouds() do t:truthy(c.spawnAt < endsAt) end
end)

test.unit("a reconnect keeps seat, score and reload without counting anything twice", function(t)
	local fake = round(3)
	local a = fake.players[2]
	fake.start()
	fake.run(fake.now() + 0.3)
	local cloud = assert(fake.live())
	fake.game.receive(a :: any, Rules.SHOOT, 1, cloud.id, fake.now())
	local shot = fake.shots()[1]
	fake.game.leave(a :: any)
	local back = { session_id = 77, player_id = a.player_id, isActive = true }
	fake.game.join(back :: any)
	local snapshot = assert(Rules.snapshot((assert(fake.last(Rules.SNAPSHOT, back :: any)))[1]))
	local mine: Rules.Player? = nil
	for _, pl in snapshot.players do if pl.player == a.player_id then mine = pl end end
	local m = assert(mine)
	t:equal(m.seat, 2)
	t:equal(m.score, shot.total)
	t:equal(m.reloadUntil, shot.reloadUntil)
	t:equal(snapshot.lastSequence, 1)
	t:equal(snapshot.lastEvent, shot.event)
	t:equal(snapshot.startsAt, 1000 + C.PREPARATION, "the round did not restart")
	local before = #fake.sent
	fake.game.receive(back :: any, Rules.SHOOT, 1, cloud.id, fake.now())
	t:equal(#fake.sent, before, "the old sequence is a duplicate")
end)

test.unit("results: ranked once, the same for everyone; nobody who scored nothing wins", function(t)
	local fake = round(5)
	fake.start()
	fake.run(1000 + C.PREPARATION + C.DURATION)
	fake.game.finish()
	fake.game.finish()
	local results = 0
	for _, s in fake.sent do if s.kind == Rules.RESULTS then results += 1 end end
	t:equal(results, 1)
	local standings = assert(Rules.standings((assert(fake.last(Rules.RESULTS)))[1]))
	t:equal(#standings, 5)
	-- Nobody shot: places, but no Starlights.
	for _, s in standings do t:equal(s.starlights, 0) end
	t:equal(next(fake.awards), nil)
end)
