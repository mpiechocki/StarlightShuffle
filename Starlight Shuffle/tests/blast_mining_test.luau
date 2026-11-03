--!strict
-- Blast Mining's schedule (Rules) and its authoritative round (Round) driven
-- through a fake cycle context with a clock the test moves: timing windows,
-- cooldowns, bombs, duplicates, forged input, disclosure, reconnection and
-- the standings.
local test = require("@moonbase/test")
local Rules = require("@project/minigames/blast_mining/Rules")
local Round = require("@project/minigames/blast_mining/Round")

local C = Rules.CONFIG

type Player = { session_id: number, player_id: number, isActive: boolean }
type Sent = { to: {Player}?, kind: string, args: {any} }

-- A seeded 0..1 generator, so schedules repeat.
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
	local context: Round.Context = {
		players = function() return players :: any end,
		award = function(player: any, n: number) awards[player.player_id] = (awards[player.player_id] or 0) + n end,
		send = function(to: any, kind: any, ...: any) table.insert(sent, { to = to, kind = kind, args = {...} }) end,
		clock = function() return now end,
		startsIn = function() return 4 end,
		identity = function(player: any) return { name = "P" .. player.player_id, outfit = nil } end,
		random = seeded(seed or 7),
	}
	local game = Round.new(context)
	local fake = { players = players, game = game, sent = sent, awards = awards }
	function fake.at(t: number) now = t end
	function fake.now(): number return now end
	function fake.last(kind: string, player: Player?): {any}?
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.kind == "game" or s.kind == kind then
				if s.kind == kind and (s.to == nil or (player ~= nil and table.find(s.to :: {Player}, player) ~= nil)) then return s.args end
			end
		end
		return nil
	end
	function fake.snapshot(player: Player?): Rules.Snapshot
		return assert(Rules.snapshot((assert(fake.last(Rules.SNAPSHOT, player)))[1]))
	end
	-- Every item disclosed so far.
	function fake.items(): {Rules.Item}
		local out: {Rules.Item} = {}
		for _, s in sent do
			if s.kind == Rules.SPAWN then
				for _, item in assert(Rules.items(s.args[1])) do table.insert(out, item) end
			end
		end
		return out
	end
	function fake.hits(): {Rules.Hit}
		local out: {Rules.Hit} = {}
		for _, s in sent do if s.kind == Rules.HIT then table.insert(out, assert(Rules.hit(s.args[1]))) end end
		return out
	end
	-- Moves the clock to [t], disclosing as the server would every tick.
	function fake.run(t: number)
		while now < t do
			now = math.min(t, now + 1 / 30)
			game.update(1 / 30)
		end
	end
	return fake
end

local function streamItems(fake: any, stream: number): {Rules.Item}
	local out: {Rules.Item} = {}
	for _, item in fake.items() do if item.stream == stream then table.insert(out, item) end end
	table.sort(out, function(a: Rules.Item, b: Rules.Item): boolean return a.strikeAt < b.strikeAt end)
	return out
end

test.unit("schedules keep the tuning: gaps, windows apart, falls, odds", function(t)
	local items = Rules.schedule(1, 0, 0, seeded(3))
	t:truthy(#items > 80)
	local kinds: {[string]: number} = { rock = 0, gem = 0, bomb = 0 }
	for i, item in items do
		kinds[item.kind] += 1
		local fall = item.strikeAt - item.spawnAt
		t:truthy(fall >= C.FALL_MIN * (1 - C.SPEED_UP) - 1e-9 and fall <= C.FALL_MAX + 1e-9)
		t:truthy(item.strikeAt <= C.DURATION - C.TAIL)
		if i > 1 then
			local gap = item.strikeAt - items[i - 1].strikeAt
			t:truthy(gap >= 0.24 - 1e-9 and gap <= 1.06 + 1e-9, "gap " .. gap)
			t:truthy(gap > 2 * C.HIT_WINDOW, "hit windows never overlap")
		end
	end
	t:truthy(kinds.rock > kinds.bomb and kinds.bomb > kinds.gem and kinds.gem > 0)
end)

test.unit("items are disclosed only shortly before they fall", function(t)
	local fake = round(2)
	fake.at(1004)
	fake.game.start()
	fake.run(1010)
	for _, item in fake.items() do
		t:truthy(item.spawnAt - C.LEAD <= 1010 + 1 / 30, "nothing far ahead is disclosed")
	end
	t:truthy(#fake.items() > 0)
end)

test.unit("a swing in the window scores once; outside it misses", function(t)
	local fake = round(1)
	local p = fake.players[1]
	fake.at(1004); fake.game.start()
	local first: Rules.Item? = nil
	while not first do
		fake.run(fake.now() + 0.1)
		local items = streamItems(fake, 1)
		for _, item in items do if item.kind ~= "bomb" then first = item; break end end
	end
	local item = first :: Rules.Item
	fake.run(item.strikeAt - 0.3)
	-- Early: a miss.
	fake.game.receive(p :: any, Rules.SWING, 1, item.strikeAt - 0.3)
	t:equal(#fake.hits(), 0)
	-- In the window (after the cooldown): a hit.
	fake.run(item.strikeAt - 0.05)
	fake.game.receive(p :: any, Rules.SWING, 2, item.strikeAt - 0.05)
	t:equal(#fake.hits(), 1)
	t:equal(fake.hits()[1].item, item.id)
	-- The same sequence again, and another swing after: never twice.
	fake.game.receive(p :: any, Rules.SWING, 2, item.strikeAt - 0.05)
	fake.run(item.strikeAt + 0.2)
	fake.game.receive(p :: any, Rules.SWING, 3, item.strikeAt + 0.2)
	local hits = fake.hits()
	for i = 2, #hits do t:truthy(hits[i].item ~= item.id) end
end)

test.unit("cooldowns: taps inside 190 ms are refused, and 410 ms after a bomb", function(t)
	local fake = round(1)
	local p = fake.players[1]
	fake.at(1004); fake.game.start()
	fake.run(1010)
	fake.game.receive(p :: any, Rules.SWING, 1, fake.now())
	fake.at(fake.now() + 0.1)
	fake.game.receive(p :: any, Rules.SWING, 2, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 2)
	fake.at(fake.now() + 0.1)
	fake.game.receive(p :: any, Rules.SWING, 3, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 2, "200 ms later is fine")
	-- Find a bomb and hit it.
	local bomb: Rules.Item? = nil
	while not bomb do
		fake.run(fake.now() + 0.1)
		for _, item in streamItems(fake, 1) do
			if item.kind == "bomb" and item.strikeAt > fake.now() + 0.3 then bomb = item; break end
		end
	end
	local b = bomb :: Rules.Item
	fake.run(b.strikeAt)
	fake.game.receive(p :: any, Rules.SWING, 4, b.strikeAt)
	local hit = fake.hits()[#fake.hits()]
	t:equal(hit.kind, "bomb")
	t:equal(hit.total, 0, "never below zero")
	t:equal(hit.slowUntil, Rules.ms(b.strikeAt + C.SLOW))
	-- 300 ms later: still slowed, refused.
	fake.at(b.strikeAt + 0.3)
	fake.game.receive(p :: any, Rules.SWING, 5, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 5)
	-- 420 ms after the bomb: allowed again.
	fake.at(b.strikeAt + 0.42)
	fake.game.receive(p :: any, Rules.SWING, 6, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 5)
	-- After the slowdown, the normal cooldown is back.
	fake.at(b.strikeAt + 1.0)
	fake.game.receive(p :: any, Rules.SWING, 7, fake.now())
	fake.at(b.strikeAt + 1.2)
	fake.game.receive(p :: any, Rules.SWING, 8, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 5)
end)

test.unit("claimed tap times are bounded; forged messages do nothing", function(t)
	local fake = round(1)
	local p = fake.players[1]
	fake.at(1004); fake.game.start()
	fake.run(1020)
	-- A tap claimed 5 s ago counts as 150 ms ago at most.
	fake.game.receive(p :: any, Rules.SWING, 1, 1015)
	local swing = assert(fake.last(Rules.SWING))
	t:equal(swing[3], Rules.ms(1020 - C.MAX_COMPENSATION))
	-- Claims from the future count as now.
	fake.at(1021)
	fake.game.receive(p :: any, Rules.SWING, 2, 5000)
	t:equal((assert(fake.last(Rules.SWING)))[3], 1021)
	-- Score claims and junk are ignored.
	local before = #fake.sent
	fake.game.receive(p :: any, "score", 999)
	fake.game.receive(p :: any, Rules.SWING, "x", 1)
	fake.game.receive(p :: any, Rules.HIT, { total = 99 })
	t:equal(#fake.sent, before)
	-- Not a miner: ignored.
	fake.game.receive({ session_id = 99, player_id = 999, isActive = true } :: any, Rules.SWING, 3, 1021)
	t:equal(#fake.sent, before)
end)

test.unit("no swings before the start or after the end", function(t)
	local fake = round(1)
	local p = fake.players[1]
	fake.at(1002)
	fake.game.receive(p :: any, Rules.SWING, 1, 1002)
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 1)
	fake.at(1004); fake.game.start()
	fake.run(1004 + C.DURATION + 0.5)
	fake.game.receive(p :: any, Rules.SWING, 2, fake.now())
	t:equal((assert(fake.last(Rules.REJECT, p)))[1], 2)
end)

test.unit("a reconnect keeps score and stream without counting anything twice", function(t)
	local fake = round(2)
	local a = fake.players[1]
	fake.at(1004); fake.game.start()
	local scored = 0
	local sequence = 0
	fake.run(1030)
	for _, item in streamItems(fake, 1) do
		if item.kind ~= "bomb" and item.strikeAt > 1030 and scored < 2 then
			fake.run(item.strikeAt)
			sequence += 1
			fake.game.receive(a :: any, Rules.SWING, sequence, item.strikeAt)
			scored += 1
		end
	end
	local total = fake.hits()[#fake.hits()].total
	fake.game.leave(a :: any)
	local back = { session_id = 77, player_id = a.player_id, isActive = true }
	fake.game.join(back :: any)
	local snapshot = fake.snapshot(back :: any)
	local mine: Rules.Miner? = nil
	for _, m in snapshot.miners do if m.player == a.player_id then mine = m end end
	t:equal((mine :: Rules.Miner).score, total)
	t:equal((mine :: Rules.Miner).stream, 1)
	t:equal(snapshot.lastSequence, sequence)
	t:equal(snapshot.startsAt, 1004, "the round did not restart")
	-- The old sequence from the new connection is a duplicate.
	local hits = #fake.hits()
	fake.game.receive(back :: any, Rules.SWING, sequence, fake.now())
	t:equal(#fake.hits(), hits)
	-- The old connection no longer swings for them.
	local before = #fake.sent
	fake.game.receive(a :: any, Rules.SWING, sequence + 1, fake.now())
	t:equal(#fake.sent, before)
end)

test.unit("standings: points, then who got there first, then id; only scorers win", function(t)
	local ranked = Rules.rank({
		{ player = 4, name = "d", score = 5, reachedAt = 10 },
		{ player = 2, name = "b", score = 7, reachedAt = 20 },
		{ player = 3, name = "c", score = 7, reachedAt = 12 },
		{ player = 1, name = "a", score = 5, reachedAt = 10 },
	})
	t:equal(ranked[1].player, 3)
	t:equal(ranked[2].player, 2)
	t:equal(ranked[3].player, 1)
	t:equal(ranked[4].player, 4)
	local fake = round(4)
	fake.at(1004); fake.game.start()
	fake.run(1004 + C.DURATION)
	fake.game.finish()
	fake.game.finish() -- idempotent
	local results = 0
	for _, s in fake.sent do if s.kind == Rules.RESULTS then results += 1 end end
	t:equal(results, 1)
	local standings = assert(Rules.standings((assert(fake.last(Rules.RESULTS)))[1]))
	t:equal(#standings, 4)
	-- Nobody swung: places, but no Starlights.
	for _, s in standings do t:equal(s.starlights, 0) end
	t:equal(next(fake.awards), nil)
end)
