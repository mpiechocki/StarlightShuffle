--!strict
-- Starcatchers' rules (Rules) and its authoritative round (Round) through a
-- fake cycle context with a clock the test moves: the exact stream hash and
-- star density, wave composition and speeds, the throw / recall / return
-- flight, one carried star and banking only at home, streak bonuses,
-- satellite hits on the net's actual position, independent streams, the
-- lineup and distant players, the wire format, and the round's intents,
-- visibility, reconnects and results.
local test = require("@moonbase/test")
local Rules = require("@project/minigames/starcatchers/Rules")
local Round = require("@project/minigames/starcatchers/Round")

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

-- Throws whenever the net is idle (or at chosen times) for a whole round.
local function play(seed: number, stream: number, choose: ((net: Rules.Net, t: number) -> boolean)?): (Rules.Net, {Rules.Event})
	local net = Rules.newNet()
	local events: {Rules.Event} = {}
	local t = 0
	while t < C.DURATION + 0.5 do
		Rules.step(net, t, seed, stream, function(e: Rules.Event) table.insert(events, e) end)
		if net.stage == "idle" and (not choose or choose(net, t)) then Rules.throw(net, t) end
		t += 1 / 30
	end
	Rules.step(net, C.DURATION + 1, seed, stream)
	return net, events
end

test.unit("the stream hash is exact, uniform-ish and independent per property", function(t)
	t:equal(Rules.random(1, 2, 3, 4), Rules.random(1, 2, 3, 4))
	t:truthy(Rules.random(1, 2, 3, 4) ~= Rules.random(1, 2, 3, 5))
	t:truthy(Rules.random(1, 2, 3, 4) ~= Rules.random(1, 3, 3, 4))
	local sum, low, high = 0, 1, 0
	for i = 1, 2000 do
		local x = Rules.random(99, 7, i, 1)
		t:truthy(x >= 0 and x < 1)
		sum += x
		if x < low then low = x end
		if x > high then high = x end
	end
	t:truthy(math.abs(sum / 2000 - 0.5) < 0.03)
	t:truthy(low < 0.01 and high > 0.99)
end)

test.unit("dense waves: four stars every 1.2 s, about 200 a round, 8 to 15 on screen", function(t)
	local crossing, samples, total = 0, 0, 0
	for i = 0, 400 do
		local d = Rules.item(42, 3, i)
		if d.at < C.DURATION then crossing += 1 end
		t:truthy(d.travel >= 1.5 and d.travel <= 1.95)
		local slot = i % 4
		if slot == 0 then t:equal(d.kind, "star"); t:truthy(math.abs(d.height - 0.27) <= 0.0175 + 1e-9) end
		if slot == 1 then t:truthy(d.kind ~= "star"); t:truthy(math.abs(d.height - 0.87) <= 0.025 + 1e-9) end
		if slot == 2 then t:truthy(math.abs(d.height - 0.57) <= 0.06 + 1e-9) end
		if slot == 3 then t:truthy(d.height >= 0.28 and d.height <= 0.72) end
		t:equal(d.value, Rules.value(d.kind))
	end
	t:truthy(crossing >= 195 and crossing <= 205)
	for e = 5, 55, 0.5 do
		local stars = Rules.field(42, 3, e)
		total += #stars
		samples += 1
	end
	local average = total / samples
	t:truthy(average >= 8 and average <= 15, "average on screen " .. average)
end)

test.unit("satellites cross about every 4.5 s at the middle heights", function(t)
	local last = 0
	for i = 0, 12 do
		local s = Rules.satellite(42, 3, i)
		t:truthy(s.height >= 0.19 and s.height <= 0.68)
		t:truthy(s.travel >= 2.2 and s.travel <= 2.7)
		t:truthy(s.at >= C.SATELLITE_FIRST + i * C.SATELLITE_EVERY and s.at <= C.SATELLITE_FIRST + i * C.SATELLITE_EVERY + C.SATELLITE_JITTER)
		if i > 0 then t:truthy(s.at - last > C.SATELLITE_EVERY - C.SATELLITE_JITTER) end
		last = s.at
	end
end)

test.unit("a throw rises under two seconds, turns at its top and returns in under one", function(t)
	local net = Rules.newNet()
	t:truthy(not Rules.throw(net, -0.1)) -- not before play
	t:truthy(Rules.throw(net, 1))
	t:truthy(not Rules.throw(net, 1)) -- one net
	local top, topAt, home = 0, 0, 0
	local time = 1
	while time < 6 do
		time += 1 / 60
		Rules.step(net, time)
		if net.stage == "rising" and net.height > top then top, topAt = net.height, time end
		if net.stage == "idle" then home = time; break end
	end
	t:truthy(topAt - 1 < 2, "rise " .. (topAt - 1))
	t:truthy(top > 0.95, "top " .. top)
	t:truthy(home - topAt < 1, "return " .. (home - topAt))
	-- A release turns it early; recalling a returning or idle net does nothing.
	t:truthy(Rules.throw(net, 7))
	Rules.step(net, 7.3)
	t:truthy(Rules.recall(net, 7.3))
	t:equal(net.stage, "reeling")
	t:truthy(not Rules.recall(net, 7.31))
	-- The flight bows out one way and home the other.
	local out = Rules.newNet()
	Rules.throw(out, 10)
	Rules.step(out, 10.6)
	local outward = Rules.offset(out, 10.6)
	t:truthy(outward > 0)
	Rules.recall(out, 10.6)
	Rules.step(out, 10.9)
	t:truthy(Rules.offset(out, 10.9) < outward)
end)

test.unit("one star per net, scored only at home, with the streak bonus", function(t)
	local net, events = play(7, 2)
	local hooks, banks, total = 0, 0, 0
	local carried = 0
	for _, e in events do
		if e.kind == "hook" then
			hooks += 1
			carried += 1
			t:truthy(carried == 1, "never two stars in the net")
		elseif e.kind == "bank" then
			banks += 1
			carried = 0
			t:equal(e.height, 0)
			total += e.delta :: number
		elseif e.kind == "snap" then
			carried = 0
		end
	end
	t:truthy(banks > 10)
	t:equal(net.score, total)
	-- Bonus: +1 at streaks 3-5, +2 at 6-8, +3 from 9.
	local deltas: {number} = {}
	local star = Rules.item(7, 2, 0) -- slot 0: an ordinary star, +1
	for k = 1, 10 do
		local home = Rules.newNet()
		home.stage, home.height, home.velocity, home.carried, home.streak, home.updatedAt = "reeling", 0.01, -1.65, star, k - 1, 5
		Rules.step(home, 5.1, nil, nil, function(e: Rules.Event) if e.delta then table.insert(deltas, e.delta) end end)
	end
	t:equal(deltas[2], 1); t:equal(deltas[3], 2); t:equal(deltas[6], 3); t:equal(deltas[9], 4); t:equal(deltas[10], 4)
	-- Nothing is left in the air after the end, and nothing scores after it.
	t:equal(net.stage, "idle")
	t:equal(net.carried, nil)
	for _, e in events do
		if e.kind == "bank" then t:truthy(e.at < C.DURATION) end
	end
end)

test.unit("a satellite on the net's path drops the catch, resets the streak and tangles 1.2 s", function(t)
	local found = false
	for seed = 1, 40 do
		local net = Rules.newNet()
		local time = 0
		while time < C.DURATION and not found do
			local scoreBefore = net.score
			local hit: Rules.Event? = nil
			Rules.step(net, time, seed, 1, function(e: Rules.Event) if e.kind == "snap" then hit = e end end)
			if hit then
				found = true
				t:equal(net.stage, "tangled")
				t:equal(net.streak, 0)
				t:equal(net.carried, nil)
				t:equal(net.score, scoreBefore) -- banked points stay
				t:truthy(math.abs(net.tangleUntil - (hit :: Rules.Event).at - C.TANGLE) < 1e-9)
				t:truthy(not Rules.throw(net, time)) -- no throw meanwhile
				local struck = 0
				for _ in net.struck do struck += 1 end
				t:equal(struck, 1)
				Rules.step(net, net.tangleUntil + 0.05, seed, 1)
				t:equal(net.stage, "idle")
				t:truthy(Rules.throw(net, net.tangleUntil + 0.05))
			end
			if net.stage == "idle" then Rules.throw(net, time) end
			time += 1 / 30
		end
		if found then break end
	end
	t:truthy(found, "some throw met a satellite")
	-- A satellite well below a high net passes it by: collisions use the net's real height.
	local sat = Rules.satellite(5, 1, 0)
	local net = Rules.newNet()
	net.stage, net.height, net.updatedAt = "rising", math.min(1, sat.height + 0.3), 0
	t:truthy(math.abs(sat.height - net.height) > C.SATELLITE_DH)
end)

test.unit("each participant's stream is their own", function(t)
	local a = Rules.item(11, 1, 5)
	local b = Rules.item(11, 2, 5)
	t:truthy(a.height ~= b.height or a.at ~= b.at or a.kind ~= b.kind)
	local netA = play(11, 1)
	local netB = play(11, 2)
	t:truthy(netA.score ~= netB.score or next(netA.consumed) ~= nil)
	-- Choosing to wait gives fewer catches than throwing always; nobody can take everything.
	local eager = play(11, 3)
	local caught = 0
	for _ in eager.consumed do caught += 1 end
	t:truthy(caught < 120, "caught " .. caught .. " of about 200")
end)

test.unit("the lineup wraps; neighbours and up to six distant players", function(t)
	local lineup = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 }
	local l, r = Rules.neighbours(lineup, 10)
	t:equal(l, 100); t:equal(r, 20)
	l, r = Rules.neighbours({ 1, 2 }, 2)
	t:equal(l, 1); t:equal(r, nil)
	l, r = Rules.neighbours({ 1 }, 1)
	t:equal(l, nil); t:equal(r, nil)
	local far = Rules.distant(lineup, 10)
	t:equal(#far, 6)
	t:equal(far[1].player, 90); t:equal(far[1].offset, -2); t:equal(far[1].depth, 1)
	t:equal(far[2].player, 30)
	local seen: {[number]: boolean} = { [10] = true, [20] = true, [100] = true }
	for _, d in far do t:truthy(not seen[d.player]); seen[d.player] = true end
	t:equal(#Rules.distant({ 1, 2, 3, 4 }, 1), 1) -- only 3 is left beyond the neighbours
	t:equal(#Rules.distant({ 1, 2, 3 }, 1), 0)
end)

test.unit("updates carry the used stars only to their owner and round-trip", function(t)
	local net, _ = play(3, 4)
	local u: Rules.Update = { player = 7, version = 3, net = net, event = { kind = "bank", at = 12.5, height = 0, item = Rules.item(3, 4, 9), delta = 4 } }
	local mine = assert(Rules.update(Rules.updateValue(u, true), 3, 4))
	local theirs = assert(Rules.update(Rules.updateValue(u, false), 3, 4))
	t:equal(mine.net.score, net.score)
	local count = 0
	for _ in mine.net.consumed do count += 1 end
	local want = 0
	for _ in net.consumed do want += 1 end
	t:equal(count, want)
	t:equal(next(theirs.net.consumed), nil)
	t:equal(assert((mine.event :: Rules.Event).item).kind, Rules.item(3, 4, 9).kind)
	t:equal(Rules.update({ player = 7, version = 1, stage = "flying" }, 3, 4), nil)
end)

local function round(count: number)
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
		random = seeded(5),
		finish = function() finishes += 1; game.finish() end,
	})
	local fake = { players = players, game = game, sent = sent, awards = awards }
	local sequences: {[number]: number} = {}
	function fake.now(): number return now end
	function fake.finishes(): number return finishes end
	function fake.start() now = 1000 + C.PREPARATION; game.start() end
	function fake.run(t: number)
		while now < t do
			now = if t - now <= 1 / 30 + 1e-9 then t else now + 1 / 30
			game.update(1 / 30)
		end
	end
	function fake.send(p: Player, kind: string): number
		sequences[p.player_id] = (sequences[p.player_id] or 0) + 1
		game.receive(p :: any, kind, sequences[p.player_id])
		return sequences[p.player_id]
	end
	function fake.to(p: Player, kind: string): {{any}}
		local out = {}
		for _, s in sent do
			if s.kind == kind and (s.to == nil or table.find(s.to :: {Player}, p)) then table.insert(out, s.args) end
		end
		return out
	end
	function fake.snapshot(p: Player): Rules.Snapshot
		local all = fake.to(p, Rules.SNAPSHOT)
		return assert(Rules.snapshot(all[#all][1]))
	end
	return fake
end

test.unit("the round simulates every net; throws are judged; updates reach only who shows them", function(t)
	local r = round(10)
	local a = r.players[1]
	t:equal(#r.to(a, Rules.REJECT), 0)
	local early = r.send(a, Rules.THROW)
	t:equal(r.to(a, Rules.REJECT)[1][1], early) -- not before play
	r.start()
	r.run(r.now() + 0.5)
	t:equal(#r.to(a, Rules.REJECT), 1)
	r.send(a, Rules.THROW)
	t:equal((r.game.net(a.player_id) :: Rules.Net).stage, "rising")
	r.send(a, Rules.THROW) -- already flying
	t:equal(#r.to(a, Rules.REJECT), 2)
	r.game.receive(a :: any, Rules.THROW, 1) -- an old sequence: ignored
	r.game.receive(a :: any, "score", 999)
	t:equal(#r.to(a, Rules.REJECT), 2)
	-- Who hears about a's net: a, its two neighbours and up to six more; nobody else.
	local snap = r.snapshot(a)
	local watchers: {[number]: boolean} = {}
	for _, p in r.players do
		local s = r.snapshot(p)
		local left, right = Rules.neighbours(s.lineup, p.player_id)
		local shows = left == a.player_id or right == a.player_id
		for _, d in Rules.distant(s.lineup, p.player_id) do if d.player == a.player_id then shows = true end end
		if shows then watchers[p.player_id] = true end
	end
	for _, s in r.sent do
		if s.kind == Rules.NET and s.args[1].player == a.player_id then
			for _, to in s.to :: {Player} do
				t:truthy(to == a or watchers[to.player_id], "update to " .. to.player_id)
				if to ~= a then t:equal(s.args[1].consumed, nil) end
			end
		end
	end
	t:equal(#snap.lineup, 10)
end)

test.unit("results rank the whole match; the top three still here are paid once", function(t)
	local r = round(5)
	r.start()
	local t0 = r.now()
	-- Players 1-4 throw whenever they can; player 5 never does.
	while r.now() < t0 + C.DURATION + 0.2 do
		for i = 1, 4 do
			local net = r.game.net(r.players[i].player_id) :: Rules.Net
			if net.stage == "idle" then r.send(r.players[i], Rules.THROW) end
		end
		r.run(r.now() + 0.1)
	end
	t:equal(r.finishes(), 1)
	r.game.finish()
	local standings = assert(Rules.standings(r.to(r.players[1], Rules.RESULTS)[1][1]))
	t:equal(#standings, 5)
	t:equal(standings[5].player, r.players[5].player_id)
	t:equal(standings[5].score, 0)
	for i = 2, 5 do t:truthy(standings[i - 1].score >= standings[i].score) end
	local paid = 0
	for id, n in r.awards do
		paid += 1
		local place = 0
		for _, s in standings do if s.player == id then place = s.place end end
		t:equal(n, ({ 5, 3, 2 })[place])
	end
	t:equal(paid, 3)
	t:truthy(standings[1].score > 20)
end)

test.unit("nobody is paid for a round without points", function(t)
	local r = round(3)
	r.start()
	r.run(r.now() + C.DURATION + 0.2)
	t:equal(r.finishes(), 1)
	local standings = assert(Rules.standings(r.to(r.players[1], Rules.RESULTS)[1][1]))
	t:equal(#standings, 3)
	t:equal(standings[1].starlights, 0)
	t:equal(next(r.awards), nil)
end)

test.unit("a reconnect keeps the score; leaving recalls a flying net", function(t)
	local r = round(3)
	local a = r.players[1]
	r.start()
	r.run(r.now() + 0.2)
	r.send(a, Rules.THROW)
	r.run(r.now() + 0.3)
	r.game.leave(a :: any)
	t:equal((r.game.net(a.player_id) :: Rules.Net).stage, "reeling")
	r.run(r.now() + 5)
	local back: Player = { session_id = 99, player_id = a.player_id, isActive = true }
	r.game.join(back :: any)
	local snap = r.snapshot(back)
	local mine: Rules.Update? = nil
	for _, u in snap.nets do if u.player == a.player_id then mine = u end end
	t:truthy(mine ~= nil)
	t:equal((mine :: Rules.Update).net.score, (r.game.net(a.player_id) :: Rules.Net).score)
	-- A latecomer watches and cannot throw.
	local late: Player = { session_id = 77, player_id = 777, isActive = true }
	r.game.join(late :: any)
	r.game.receive(late :: any, Rules.THROW, 1)
	t:equal(#r.to(late, Rules.REJECT), 0)
	t:truthy(#r.snapshot(late).nets > 0)
end)
