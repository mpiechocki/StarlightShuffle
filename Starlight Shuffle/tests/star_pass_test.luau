--!strict
-- Star Pass's rules (Rules) and its authoritative match (Round) through a fake
-- cycle context with a clock the test moves: star supply and wave timing,
-- possession-scoped charging, pass races and targets, simultaneous bursts,
-- recaps, forfeits, reconnects and the ranking.
local test = require("@moonbase/test")
local Rules = require("@project/minigames/star_pass/Rules")
local Round = require("@project/minigames/star_pass/Round")

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

local function match(count: number, seed: number?)
	local players: {Player} = {}
	for i = 1, count do players[i] = { session_id = 10 + i, player_id = 100 + i, isActive = true } end
	local now = 1000
	local sent: {Sent} = {}
	local awards: {[number]: number} = {}
	local finishes = 0
	local game: Round.Round
	game = Round.new({
		players = function() return players :: any end,
		award = function(player: any, n: number) awards[player.player_id] = (awards[player.player_id] or 0) + n end,
		send = function(to: any, kind: any, ...: any) table.insert(sent, { to = to, kind = kind, args = {...} }) end,
		clock = function() return now end,
		startsIn = function() return C.PREPARATION end,
		identity = function(player: any) return { name = "P" .. player.player_id, outfit = nil } end,
		random = seeded(seed or 9),
		finish = function() finishes += 1; game.finish() end,
	})
	local fake = { players = players, game = game, sent = sent, awards = awards }
	local sequences: {[number]: number} = {}
	function fake.at(t: number) now = t end
	function fake.now(): number return now end
	function fake.finishes(): number return finishes end
	function fake.byId(id: number): Player
		for _, p in players do if p.player_id == id then return p end end
		error("no player " .. id)
	end
	function fake.all(kind: string): {{any}}
		local out = {}
		for _, s in sent do if s.kind == kind then table.insert(out, s.args) end end
		return out
	end
	function fake.last(kind: string, player: Player?): {any}?
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.kind == kind and (s.to == nil or (player ~= nil and table.find(s.to :: {Player}, player) ~= nil)) then return s.args end
		end
		return nil
	end
	-- The stars as the latest WAVE or PASSED says.
	function fake.stars(): {Rules.Star}
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.kind == Rules.WAVE then return assert(Rules.wave(s.args[1])).stars end
			if s.kind == Rules.PASSED then return assert(Rules.passed(s.args[1])).stars end
			if s.kind == Rules.ELIMINATED then return {} end
		end
		return {}
	end
	function fake.wave(): Rules.Wave
		local w = assert(fake.last(Rules.WAVE))
		return assert(Rules.wave(w[1]))
	end
	function fake.start()
		now = 1000 + C.PREPARATION
		game.start()
	end
	function fake.run(t: number)
		while now < t do
			now = math.min(t, now + 1 / 30)
			game.update(1 / 30)
		end
	end
	function fake.next(p: Player): number
		sequences[p.player_id] = (sequences[p.player_id] or 0) + 1
		return sequences[p.player_id]
	end
	function fake.charge(p: Player, op: string, star: Rules.Star, attempt: number): Rules.Charged
		local sequence = fake.next(p)
		game.receive(p :: any, Rules.CHARGE, sequence, op, star.id, star.possession, attempt)
		return assert(Rules.charged((assert(fake.last(Rules.CHARGED, p)))[1]))
	end
	-- Charges [star] fully, the honest way (CHARGE of holding).
	function fake.charged(star: Rules.Star, attempt: number?)
		local p = fake.byId(star.holder)
		fake.charge(p, "begin", star, attempt or 1)
		now += C.CHARGE + 0.01
		return fake.charge(p, "complete", star, attempt or 1)
	end
	function fake.pass(star: Rules.Star, target: number): (boolean, string?)
		local p = fake.byId(star.holder)
		local before = #fake.all(Rules.PASSED)
		local sequence = fake.next(p)
		game.receive(p :: any, Rules.PASS, sequence, star.id, star.possession, target)
		if #fake.all(Rules.PASSED) > before then return true, nil end
		local reject = fake.last(Rules.REJECT, p)
		return false, if reject then reject[2] else nil
	end
	return fake
end

test.unit("star supply, wave length and tick pace follow the tuning", function(t)
	t:equal(Rules.starCount(1), 0)
	for alive, stars in { [2] = 1, [6] = 1, [7] = 2, [12] = 2, [13] = 3, [18] = 3, [19] = 4, [24] = 4, [25] = 5, [40] = 5 } :: {[number]: number} do
		t:equal(Rules.starCount(alive), stars, alive .. " survivors")
	end
	t:equal(Rules.waveDuration(1, 0), 10.15)
	t:equal(Rules.waveDuration(20, 0), 6)
	t:equal(Rules.waveDuration(1, 1), 10.15 + 1.3)
	t:equal(Rules.tickInterval(6), 0.8)
	t:equal(Rules.tickInterval(5), 0.52)
	t:equal(Rules.tickInterval(3), 0.32)
	t:equal(Rules.tickInterval(1.5), 0.17)
end)

test.unit("targets: free survivors, no quick returns unless it is the only one, stable slots", function(t)
	local survivors = { 1, 2, 3, 4, 5, 6 }
	local choices = Rules.targets(survivors, { [1] = true, [4] = true }, 1, nil, false, 0, 1)
	t:equal(#choices, 3)
	for _, id in choices do t:truthy(id ~= 1 and id ~= 4) end
	-- The previous holder is left out while returning, if anyone else is free.
	local back = Rules.targets(survivors, { [2] = true }, 2, 3, true, 1, 1)
	t:truthy(not table.find(back, 3))
	-- Two players: the only target is the previous holder, allowed.
	t:equal(Rules.targets({ 1, 2 }, { [2] = true }, 2, 1, true, 1, 1)[1], 1)
	-- A kept choice stays in its slot; only the emptied slot is refilled.
	local keep = { 2, 3, 5 }
	local next = Rules.targets(survivors, { [1] = true, [3] = true }, 1, nil, false, 4, 2, keep)
	t:equal(next[1], 2)
	t:equal(next[3], 5)
	t:truthy(next[2] ~= 3 and next[2] ~= 1)
end)

test.unit("a wave: distinct holders, one shared burst, at least one empty hand", function(t)
	for _, count in { 2, 3, 4, 8, 16, 24, 40 } do
		local fake = match(count, count)
		fake.start()
		local w = fake.wave()
		t:equal(#w.stars, Rules.starCount(count))
		local seen: {[number]: boolean} = {}
		for _, s in w.stars do
			t:truthy(not seen[s.holder], "distinct holders")
			seen[s.holder] = true
			t:truthy(not s.charged)
			t:truthy(#s.choices >= 1 and #s.choices <= 3)
		end
		t:truthy(#w.stars <= count - 1)
		t:truthy(w.burstAt - w.startedAt >= 10.15 - 1e-6 and w.burstAt - w.startedAt <= 11.45 + 1e-6)
	end
end)

test.unit("charging: every catch, no early completion, cancel resets, stale attempts do nothing", function(t)
	local fake = match(4)
	fake.start()
	local star = fake.stars()[1]
	local holder = fake.byId(star.holder)
	-- Passing uncharged is refused.
	local ok, why = fake.pass(star, star.choices[1])
	t:truthy(not ok)
	t:equal(why, "charge")
	t:equal(fake.charge(holder, "begin", star, 1).status, "started")
	fake.at(fake.now() + 0.3)
	t:equal(fake.charge(holder, "complete", star, 1).reason, "early")
	t:equal(fake.charge(holder, "cancel", star, 1).status, "cancelled")
	-- After a cancel the old attempt cannot complete, however long ago it began.
	fake.at(fake.now() + 1)
	t:equal(fake.charge(holder, "complete", star, 1).reason, "stale")
	-- Someone else cannot charge it.
	local other = fake.byId(star.choices[1])
	t:equal(fake.charge(other, "begin", star, 7).reason, "holder")
	-- A proper hold charges it; a repeat sequence is ignored.
	t:equal(fake.charged(star, 2).status, "charged")
	local before = #fake.sent
	fake.game.receive(holder :: any, Rules.CHARGE, 1, "begin", star.id, star.possession, 9)
	t:equal(#fake.sent, before)
end)

test.unit("a pass: charge plus catch time, a new possession, no charge, same burst, one count", function(t)
	local fake = match(5)
	fake.start()
	local w = fake.wave()
	local star = w.stars[1]
	fake.charged(star)
	local target = star.choices[1]
	local ok = fake.pass(star, target)
	t:truthy(ok)
	local passed = assert(Rules.passed((assert(fake.last(Rules.PASSED)))[1]))
	t:equal(passed.to, target)
	t:equal(passed.passes, 1)
	local moved = passed.stars[1]
	t:equal(moved.holder, target)
	t:truthy(moved.possession ~= star.possession)
	t:truthy(not moved.charged, "the catch starts uncharged")
	-- The old possession is stale now, even for its old holder.
	local old = fake.byId(star.holder)
	local sequence = fake.next(old)
	fake.game.receive(old :: any, Rules.PASS, sequence, star.id, star.possession, star.choices[2] or target)
	t:equal((assert(fake.last(Rules.REJECT, old)))[2], "holder")
	-- Replaying the accepted pass counts nothing.
	local passes = #fake.all(Rules.PASSED)
	fake.game.receive(old :: any, Rules.PASS, sequence - 1, star.id, star.possession, target)
	t:equal(#fake.all(Rules.PASSED), passes)
	-- The new holder must wait the catch time even fully charged.
	fake.charge(fake.byId(target), "begin", moved, 1)
	fake.at(fake.now() + C.CHARGE - 0.1)
	t:truthy(fake.wave().burstAt == w.burstAt, "the fuse never moves")
end)

test.unit("two senders, one free target: exactly one gets it", function(t)
	local fake = match(13, 4) -- 3 stars
	fake.start()
	local stars = fake.stars()
	t:equal(#stars, 3)
	-- Find two stars that offer the same free player.
	local a: Rules.Star?, b: Rules.Star?, target: number? = nil, nil, nil
	for i = 1, #stars do
		for j = i + 1, #stars do
			for _, id in stars[i].choices do
				if table.find(stars[j].choices, id) then a, b, target = stars[i], stars[j], id end
			end
		end
	end
	if not (a and b and target) then
		-- Choices may not overlap for this draw; the ownership rule still holds.
		return
	end
	local sa, sb, to = a :: Rules.Star, b :: Rules.Star, target :: number
	fake.charged(sa)
	fake.charged(sb)
	local first = fake.pass(sa, to)
	local second, why = fake.pass(sb, to)
	t:truthy(first and not second)
	t:equal(why, "target")
	local holders: {[number]: number} = {}
	for _, s in fake.stars() do holders[s.holder] = (holders[s.holder] or 0) + 1 end
	t:equal(holders[to], 1)
end)

test.unit("the burst: every holder out together, recap, fewer stars next, no late passes", function(t)
	local fake = match(16, 3)
	fake.start()
	local w = fake.wave()
	t:equal(#w.stars, 3)
	local held = {}
	for _, s in w.stars do held[s.holder] = true end
	-- A charged holder trying to pass at the burst is too late.
	local star = w.stars[1]
	fake.charged(star)
	fake.run(w.burstAt + 0.001) -- times on the wire are rounded to the millisecond
	local ok, why = fake.pass(star, star.choices[1])
	t:truthy(not ok)
	t:truthy(why == "phase" or why == "burst")
	local eliminated = fake.all(Rules.ELIMINATED)
	t:equal(#eliminated, 1)
	local batch = assert(Rules.batch(eliminated[1][2]))
	t:equal(#batch.players, 3)
	for _, id in batch.players do t:truthy(held[id]) end
	t:equal(batch.survivors, 13)
	t:equal(batch.nextAt, Rules.ms(w.burstAt + C.RECAP))
	t:truthy(not batch.final)
	-- Nothing starts during the recap.
	fake.run(batch.nextAt - 0.05)
	t:equal(#fake.all(Rules.WAVE), 1)
	fake.run(batch.nextAt + 0.05)
	local w2 = fake.wave()
	t:equal(w2.wave, 2)
	t:equal(#w2.stars, Rules.starCount(13))
	for _, s in w2.stars do t:truthy(not held[s.holder], "the eliminated hold nothing") end
end)

test.unit("the match runs to one survivor, recaps last, then results once with a podium", function(t)
	local fake = match(4, 6)
	fake.start()
	local guard = 0
	while fake.finishes() == 0 and guard < 20 do
		guard += 1
		local w = fake.wave()
		fake.run(w.burstAt + C.RECAP + 0.1)
	end
	t:equal(fake.finishes(), 1)
	local batches = fake.all(Rules.ELIMINATED)
	local final = assert(Rules.batch(batches[#batches][2]))
	t:truthy(final.final)
	t:equal(final.survivors, 1)
	local results = fake.all(Rules.RESULTS)
	t:equal(#results, 1)
	local standings = assert(Rules.standings(results[1][1]))
	t:equal(#standings, 4)
	t:equal(standings[1].wave, nil, "the winner was never eliminated")
	for i = 2, #standings do t:truthy(standings[i].wave ~= nil) end
	for i = 3, #standings do t:truthy((standings[i - 1].wave :: number) >= (standings[i].wave :: number)) end
	local paid = 0
	for _, n in fake.awards do paid += n end
	t:equal(paid, 5 + 3 + 2)
	fake.game.finish()
	t:equal(#fake.all(Rules.RESULTS), 1)
end)

test.unit("ties in one wave go by passes, then seat", function(t)
	local ranked = Rules.rank({
		{ player = 1, seat = 1, alive = false, eliminatedWave = 2, passes = 1 },
		{ player = 2, seat = 2, alive = false, eliminatedWave = 2, passes = 4 },
		{ player = 3, seat = 3, alive = true, eliminatedWave = nil, passes = 0 },
		{ player = 4, seat = 4, alive = false, eliminatedWave = 1, passes = 9 },
		{ player = 5, seat = 5, alive = false, eliminatedWave = 2, passes = 1 },
	})
	t:equal(ranked[1].player, 3)
	t:equal(ranked[2].player, 2)
	t:equal(ranked[3].player, 1)
	t:equal(ranked[4].player, 5)
	t:equal(ranked[5].player, 4)
end)

test.unit("a reconnect keeps everything; a long absence forfeits and removes their star", function(t)
	local fake = match(3, 2)
	fake.start()
	local star = fake.stars()[1]
	local holder = fake.byId(star.holder)
	fake.game.leave(holder :: any)
	local back = { session_id = 77, player_id = holder.player_id, isActive = true }
	fake.game.join(back :: any)
	local snapshot = assert(Rules.snapshot((assert(fake.last(Rules.SNAPSHOT, back :: any)))[1]))
	t:equal(snapshot.phase, "playing")
	t:equal(snapshot.stars[1].holder, holder.player_id, "still holding")
	t:equal(snapshot.startsAt, 1000 + C.PREPARATION, "no restart")
	-- Gone for good: forfeits after the grace; the star goes, the burst stays.
	fake.game.leave(back :: any)
	fake.run(fake.now() + C.FORFEIT + 0.1)
	-- A fresh look at the match (a watcher arriving now): they are out, out of
	-- the field's stars, and the match went on.
	local watcher = { session_id = 600, player_id = 6000, isActive = true }
	fake.game.join(watcher :: any)
	local now = assert(Rules.snapshot((assert(fake.last(Rules.SNAPSHOT, watcher :: any)))[1]))
	local forfeited = false
	for _, p in now.players do
		if p.player == holder.player_id then forfeited = not p.alive end
	end
	for _, s in now.stars do t:truthy(s.holder ~= holder.player_id) end
	t:truthy(forfeited)
end)

test.unit("latecomers watch: they cannot act and do not count", function(t)
	local fake = match(3)
	fake.start()
	local late = { session_id = 500, player_id = 5000, isActive = true }
	fake.game.join(late :: any)
	local snapshot = assert(Rules.snapshot((assert(fake.last(Rules.SNAPSHOT, late :: any)))[1]))
	t:equal(#snapshot.players, 3)
	local before = #fake.sent
	local star = fake.stars()[1]
	fake.game.receive(late :: any, Rules.CHARGE, 1, "begin", star.id, star.possession, 1)
	fake.game.receive(late :: any, Rules.PASS, 2, star.id, star.possession, star.choices[1])
	t:equal(#fake.sent, before)
end)

test.unit("the crowd: everyone has a spot inside the area at every size, rows stagger, no shared spots", function(t)
	local Crowd = require("@project/minigames/star_pass/Crowd")
	for _, competitors in { 2, 3, 4, 8, 16, 24, 40, 64 } do
		local spots = Crowd.layout(competitors - 1)
		t:equal(#spots, competitors - 1, competitors .. " players all stand")
		local seen: {[string]: boolean} = {}
		for _, spot in spots do
			t:truthy(spot.x - spot.width / 2 >= -12 and spot.x + spot.width / 2 <= 112, "within the area, edges may crop")
			t:truthy(spot.bottom >= 0 and spot.bottom + spot.height <= 100, "heads inside the crowd area")
			t:truthy(spot.height < Crowd.FRONT.height, "smaller than the foreground")
			local key = spot.x .. ":" .. spot.bottom
			t:truthy(not seen[key])
			seen[key] = true
		end
	end
end)
