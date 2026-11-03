--!strict
-- Pillow Fight's rules (Rules) and its authoritative round (Round) through a
-- fake cycle context with a clock the test moves: grouping for every roster
-- size, the schedule, charge thresholds, cooldowns, dodge windows, damage,
-- knockouts, respawn protection, room isolation, the end-of-round cutoff, the
-- one-winner order, rewards, reconnects, forfeits and bots.
local test = require("@moonbase/test")
local Rules = require("@project/minigames/pillow_fight/Rules")
local Round = require("@project/minigames/pillow_fight/Round")

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
	local finishes = 0
	local game: Round.Round
	game = Round.new({
		players = function() return players :: any end,
		award = function(player: any, n: number) awards[player.player_id] = (awards[player.player_id] or 0) + n end,
		send = function(to: any, kind: any, ...: any) table.insert(sent, { to = to, kind = kind, args = {...} }) end,
		clock = function() return now end,
		startsIn = function() return C.INSTRUCTIONS end,
		identity = function(player: any) return { name = "P" .. player.player_id, outfit = nil } end,
		random = seeded(seed or 7),
		finish = function() finishes += 1; game.finish() end,
	})
	local fake = { players = players, game = game, sent = sent, awards = awards }
	local sequences: {[number]: number} = {}
	function fake.at(t: number) now = t end
	function fake.now(): number return now end
	function fake.finishes(): number return finishes end
	function fake.last(kind: string, player: Player): {any}?
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.kind == kind and (s.to == nil or table.find(s.to :: {Player}, player) ~= nil) then return s.args end
		end
		return nil
	end
	function fake.snapshot(player: Player): Rules.Snapshot
		return assert(Rules.snapshot(assert(fake.last(Rules.SNAPSHOT, player))[1]))
	end
	function fake.events(player: Player): {Rules.Event}
		local out: {Rules.Event} = {}
		for _, s in sent do
			if s.kind == Rules.EVENT and s.to and table.find(s.to :: {Player}, player) then table.insert(out, assert(Rules.event(s.args[1]))) end
		end
		return out
	end
	function fake.kinds(player: Player, kind: string): number
		local n = 0
		for _, e in fake.events(player) do if e.kind == kind then n += 1 end end
		return n
	end
	function fake.schedule(): Rules.Schedule
		local s = fake.snapshot(players[1])
		return { startsAt = s.startsAt, playAt = s.playAt, endsAt = s.endsAt, rooms = s.rooms }
	end
	-- Starts the cycle's play and moves to the fight.
	function fake.fight()
		now = 1000 + C.INSTRUCTIONS
		game.start()
		fake.run(fake.schedule().playAt)
	end
	function fake.run(t: number)
		while now < t do
			-- Whole steps, then exactly t (no drift from adding thirds).
			now = if t - now <= 1 / 30 + 1e-9 then t else now + 1 / 30
			game.update(1 / 30)
		end
	end
	function fake.id(p: Player): number return assert(fake.snapshot(p).me) end
	function fake.actor(p: Player, participant: number?): Rules.Actor
		local _, actors = game.inspect(p)
		local want = participant or fake.id(p)
		for _, a in actors do if a.participant == want then return a end end
		error("no actor " .. want)
	end
	function fake.send(p: Player, kind: string, a: any?): number
		sequences[p.player_id] = (sequences[p.player_id] or 0) + 1
		game.receive(p :: any, kind, sequences[p.player_id], a)
		return sequences[p.player_id]
	end
	-- The REJECT reason for [sequence], if any.
	function fake.rejected(p: Player, sequence: number): string?
		for _, s in sent do
			if s.kind == Rules.REJECT and s.to and table.find(s.to :: {Player}, p) and s.args[1] == sequence then return s.args[2] end
		end
		return nil
	end
	-- Charges for [hold] seconds and throws at [target]; the REJECT reason or nil.
	function fake.throw(p: Player, target: Player, hold: number): string?
		local why = fake.rejected(p, fake.send(p, Rules.CHARGE, "begin"))
		if why then return why end
		fake.run(now + hold)
		return fake.rejected(p, fake.send(p, Rules.THROW, fake.id(target)))
	end
	return fake
end

test.unit("grouping balances every roster from 1 to 24 humans", function(t)
	t:equal(#Rules.groupPlan(0), 0)
	for h = 1, 24 do
		local ids: {number} = {}
		for i = 1, h do ids[i] = i end
		local plan = Rules.groupPlan(h)
		local rooms = Rules.assign(ids, seeded(h))
		t:equal(#rooms, #plan)
		local seen: number, low: number, high: number = 0, math.huge, 0
		for i, members in rooms do
			seen += #members
			if #members < low then low = #members end
			if #members > high then high = #members end
			t:truthy(#members >= 1, "no bot-only room")
			t:truthy(plan[i] >= 3, "no room of two")
			t:truthy(#members <= plan[i])
			if h > 4 then t:equal(plan[i], 4) end
		end
		t:equal(seen, h)
		t:truthy(high - low <= 1, "humans differ by at most one at " .. h)
	end
	t:equal(Rules.groupPlan(1)[1], 3)
	t:equal(Rules.groupPlan(2)[1], 3)
	t:equal(Rules.groupPlan(4)[1], 4)
	local five = Rules.assign({ 1, 2, 3, 4, 5 }, seeded(3))
	t:equal(#five[1] + #five[2], 5)
	t:equal(math.max(#five[1], #five[2]), 3) -- 3H+1B and 2H+2B, never 4H and a lone human
end)

test.unit("rosters fill with labelled bots after the humans and draw unique tickets", function(t)
	for _, h in { 1, 2, 5, 9 } do
		local r = round(h)
		local s = r.snapshot(r.players[1])
		local humans, bots, draws = 0, 0, {}
		local perRoom: {[number]: {humans: number, total: number}} = {}
		for _, pt in s.participants do
			perRoom[pt.room] = perRoom[pt.room] or { humans = 0, total = 0 }
			perRoom[pt.room].total += 1
			if pt.bot then
				bots += 1
				t:truthy(string.find(pt.name, "· bot", 1, true) ~= nil)
				t:truthy(pt.doll ~= nil)
			else humans += 1; perRoom[pt.room].humans += 1 end
			t:truthy(not (draws[pt.draw]))
			draws[pt.draw] = true
		end
		t:equal(humans, h)
		local plan = Rules.groupPlan(h)
		local total = 0
		for _, n in plan do total += n end
		t:equal(humans + bots, total)
		for room, counts in perRoom do
			t:equal(counts.total, plan[room])
			t:truthy(counts.humans >= 1)
		end
		for i = 1, total do t:truthy(draws[i]) end
		t:equal(s.rooms, #plan)
	end
end)

test.unit("the reveal only runs with several rooms", function(t)
	local one = Rules.schedule(100, 1)
	t:equal(one.playAt, 100 + C.COUNTDOWN)
	t:equal(Rules.phaseAt(one, 99), "instructions")
	t:equal(Rules.phaseAt(one, 100), "countdown")
	local two = Rules.schedule(100, 2)
	t:equal(Rules.phaseAt(two, 101), "reveal")
	t:equal(Rules.phaseAt(two, 100 + C.REVEAL + 1), "countdown")
	t:equal(Rules.phaseAt(two, two.playAt), "playing")
	t:equal(two.endsAt, two.playAt + C.PLAY)
	t:equal(Rules.phaseAt(two, two.endsAt), "over")
	t:equal(Rules.LONGEST, 67)
end)

test.unit("charges: too short does not throw, 0.9 s throws two hearts, held too long cancels", function(t)
	local r = round(4)
	local a, b = r.players[1], r.players[2]
	-- Nothing before play.
	t:equal(r.rejected(a, r.send(a, Rules.CHARGE, "begin")), "phase")
	r.fight()
	t:equal(r.throw(a, b, 0.1), "short")
	t:equal(#r.snapshot(a).projectiles + r.kinds(a, "throw"), 0)
	t:truthy(not (r.actor(a).charging))
	t:equal(r.throw(a, b, 0.5), nil)
	local thrown = r.events(a)[#r.events(a)]
	t:equal(thrown.kind, "throw")
	t:equal((thrown.projectile :: Rules.Projectile).power, 1)
	t:equal((thrown.projectile :: Rules.Projectile).impactAt - (thrown.projectile :: Rules.Projectile).startedAt, C.FLIGHT)
	-- The cooldown: a new charge waits a second.
	t:equal(r.rejected(a, r.send(a, Rules.CHARGE, "begin")), "cooldown")
	r.run(r.now() + C.THROW_COOLDOWN)
	t:equal(r.throw(a, b, 0.95), nil)
	t:equal((r.events(a)[#r.events(a)].projectile :: Rules.Projectile).power, 2)
	r.run(r.now() + C.THROW_COOLDOWN + 0.1)
	-- Held past MAX_CHARGE: cancelled by the server, nothing to release.
	t:equal(r.rejected(a, r.send(a, Rules.CHARGE, "begin")), nil)
	r.run(r.now() + C.MAX_CHARGE + 0.1)
	t:truthy(not (r.actor(a).charging))
	t:equal(r.rejected(a, r.send(a, Rules.THROW, r.id(b))), "charge")
end)

test.unit("hits deal damage, stun, score; three hearts down is a knockout, respawn and protection", function(t)
	local r = round(4)
	local a, b = r.players[1], r.players[2]
	r.fight()
	-- b is charging when the full-power pillow lands: two hearts and the charge is gone.
	t:equal(r.throw(a, b, 0.95), nil)
	r.send(b, Rules.CHARGE, "begin")
	t:truthy(r.actor(b).charging)
	r.run(r.now() + C.FLIGHT + 0.05)
	local victim = r.actor(b)
	t:equal(victim.hp, 1)
	t:truthy(not (victim.charging))
	t:truthy(victim.stunnedUntil > r.now())
	t:equal(r.actor(a).score, 1)
	t:equal(r.actor(a).hits, 1)
	-- One more: knockout (+1 +3), b is out for RESPAWN.
	r.run(r.now() + C.THROW_COOLDOWN)
	t:equal(r.throw(a, b, 0.3), nil)
	r.run(r.now() + C.FLIGHT + 0.05)
	victim = r.actor(b)
	t:equal(victim.hp, 0)
	t:equal(victim.deaths, 1)
	t:equal(r.actor(a).kos, 1)
	t:equal(r.actor(a).score, 1 + 1 + 3)
	t:equal(r.kinds(a, "ko"), 1)
	-- Knocked out: not a valid target, cannot act.
	r.run(r.now() + C.THROW_COOLDOWN)
	t:equal(r.throw(a, b, 0.3), "target")
	t:equal(r.rejected(b, r.send(b, Rules.DODGE)), "out")
	-- Back with three hearts and protection: a pillow landing inside it is blocked.
	r.run(victim.respawnAt + 0.01)
	victim = r.actor(b)
	t:equal(victim.hp, C.HEARTS)
	t:truthy(victim.protectedUntil > r.now())
	local c = r.players[3]
	t:equal(r.throw(c, b, 0.185), nil)
	local shot = r.events(c)[#r.events(c)].projectile :: Rules.Projectile
	t:truthy(shot.impactAt <= r.actor(b).protectedUntil)
	t:truthy(not (Rules.threatens(shot, r.actor(b)))) -- no warning for it
	r.run(shot.impactAt + 0.05)
	t:equal(r.actor(b).hp, C.HEARTS)
	t:equal(r.kinds(c, "blocked"), 1)
	t:equal(r.actor(c).score, 0)
end)

test.unit("a dodge avoids a pillow only inside its window and then cools down", function(t)
	local r = round(4)
	local a, b = r.players[1], r.players[2]
	r.fight()
	t:equal(r.throw(a, b, 0.3), nil)
	local shot = r.events(a)[#r.events(a)].projectile :: Rules.Projectile
	r.run(shot.impactAt - 0.3)
	t:equal(r.rejected(b, r.send(b, Rules.DODGE)), nil)
	t:truthy(not (Rules.threatens(shot, r.actor(b))))
	r.run(shot.impactAt + 0.05)
	t:equal(r.actor(b).hp, C.HEARTS)
	t:equal(r.kinds(a, "miss"), 1)
	t:equal(r.actor(a).score, 0)
	-- Too early: the window is over when it lands.
	r.run(r.now() + C.DODGE_COOLDOWN)
	t:equal(r.throw(a, b, 0.3), nil)
	shot = r.events(a)[#r.events(a)].projectile :: Rules.Projectile
	r.run(shot.impactAt - 0.7)
	t:equal(r.rejected(b, r.send(b, Rules.DODGE)), nil)
	t:equal(r.rejected(b, r.send(b, Rules.DODGE)), "cooldown")
	r.run(shot.impactAt + 0.05)
	t:equal(r.actor(b).hp, C.HEARTS - 1)
end)

test.unit("throws are judged on the server: self, other rooms, replays and junk do nothing", function(t)
	local r = round(8)
	local a = r.players[1]
	r.fight()
	local mine = r.snapshot(a)
	local stranger: number? = nil
	for _, pt in mine.participants do
		local pa = mine.participants[mine.me :: number]
		if pt.room ~= pa.room then stranger = pt.id end
	end
	t:truthy(stranger ~= nil)
	r.send(a, Rules.CHARGE, "begin")
	r.run(r.now() + 0.4)
	t:equal(r.rejected(a, r.send(a, Rules.THROW, stranger)), "target")
	r.send(a, Rules.CHARGE, "begin")
	r.run(r.now() + 0.4)
	t:equal(r.rejected(a, r.send(a, Rules.THROW, r.id(a))), "target")
	t:equal(r.kinds(a, "throw"), 0)
	-- A replayed sequence is ignored; junk is ignored.
	r.game.receive(a :: any, Rules.DODGE, 1)
	r.game.receive(a :: any, Rules.THROW, "x", {})
	r.game.receive(a :: any, "shield", 99)
	t:equal(r.kinds(a, "dodge"), 0)
	-- Other rooms' events never reach us.
	for _, e in r.events(a) do t:equal(e.room, mine.participants[mine.me :: number].room) end
end)

test.unit("simultaneous pillows cannot knock out the same player twice; late pillows do not score", function(t)
	local r = round(4)
	local a, b, c, d = r.players[1], r.players[2], r.players[3], r.players[4]
	r.fight()
	r.send(a, Rules.CHARGE, "begin"); r.send(c, Rules.CHARGE, "begin"); r.send(d, Rules.CHARGE, "begin")
	r.run(r.now() + 0.95)
	r.send(a, Rules.THROW, r.id(b)); r.send(c, Rules.THROW, r.id(b)); r.send(d, Rules.THROW, r.id(b))
	r.run(r.now() + C.FLIGHT + 0.05)
	t:equal(r.actor(b).deaths, 1)
	t:equal(r.kinds(a, "ko"), 1)
	t:equal(r.kinds(a, "fizzle"), 1) -- the third finds nobody standing
	-- A pillow thrown just before the end lands after it: nothing.
	local s = r.schedule()
	r.run(s.endsAt - 0.6)
	local before = r.actor(c).score
	t:equal(r.throw(c, d, 0.2), nil)
	r.run(s.endsAt + 0.1)
	t:equal(r.actor(c).score, before)
	t:equal(r.actor(d).hp, C.HEARTS)
	t:equal(r.finishes(), 1)
end)

test.unit("one winner per room by score, knockouts, hits, deaths, then the draw ticket", function(t)
	local function s(id: number, score: number, kos: number, hits: number, deaths: number, draw: number): Rules.Stats
		return { participant = id, score = score, kos = kos, hits = hits, deaths = deaths, draw = draw }
	end
	local cases: {{any}} = {
		{ s(1, 5, 0, 5, 0, 4), s(2, 9, 1, 5, 0, 1), 2, "score" },
		{ s(1, 8, 1, 5, 0, 4), s(2, 8, 0, 8, 0, 1), 1, "knockouts" },
		{ s(1, 6, 0, 6, 0, 4), s(2, 6, 0, 6, 0, 1), 2, "drawOrder" },
		{ s(1, 9, 1, 6, 2, 1), s(2, 9, 1, 6, 1, 4), 2, "deaths" },
		{ s(1, 0, 0, 0, 0, 3), s(2, 0, 0, 0, 0, 2), 2, "drawOrder" },
	}
	for _, case in cases do
		local ranked = Rules.rank({ case[1], case[2], s(3, -0, 0, 0, 9, 9) })
		t:equal(ranked[1].participant, case[3])
		t:equal(Rules.tieBreak(ranked), case[4])
	end
	-- Hits before deaths.
	local ranked = Rules.rank({ s(1, 7, 1, 3, 0, 1), s(2, 7, 1, 4, 3, 2) })
	t:equal(ranked[1].participant, 2)
	t:equal(Rules.tieBreak(ranked), "hits")
end)

test.unit("results: an all-zero room still has one winner but pays nobody; others see only winners", function(t)
	local r = round(8)
	r.fight()
	r.run(r.schedule().endsAt + 0.1)
	t:equal(r.finishes(), 1)
	r.game.finish() -- the cycle's own finish afterwards changes nothing
	t:equal(next(r.awards), nil) -- nobody scored
	local p = r.players[1]
	local results = assert(Rules.results(assert(r.last(Rules.RESULTS, p))[1]))
	t:equal(#results, 2)
	local mine = results[1]
	t:equal(mine.room, r.snapshot(p).participants[r.id(p)].room)
	t:equal(mine.status, "completed")
	t:equal(#mine.placements, 4)
	local places = {}
	for _, pl in mine.placements do
		t:truthy(not places[pl.place]); places[pl.place] = true
		t:equal(pl.starlights, 0)
	end
	t:equal(mine.winner, mine.placements[1].participant)
	t:equal(mine.tieBreak, "drawOrder")
	t:equal(#results[2].placements, 1) -- other rooms: their winner only
end)

test.unit("a bot can win its room but is never paid", function(t)
	local r = round(1, 11)
	local p = r.players[1]
	r.fight()
	-- The human does nothing; the bots fight on the same rules.
	r.run(r.schedule().endsAt + 0.1)
	local results = assert(Rules.results(assert(r.last(Rules.RESULTS, p))[1]))
	local room = results[1]
	t:equal(room.status, "completed")
	t:truthy(r.kinds(p, "throw") > 0)
	local winner = r.snapshot(p).participants[room.winner :: number]
	t:truthy(winner.bot)
	-- Bots take places but no Starlights, and the idle human scored nothing.
	for _, pl in room.placements do t:equal(pl.starlights, 0) end
	t:equal(next(r.awards), nil)
end)

test.unit("only players who scored are paid, by their place", function(t)
	local r = round(4)
	local a, b = r.players[1], r.players[2]
	r.fight()
	t:equal(r.throw(a, b, 0.3), nil)
	r.run(r.now() + C.FLIGHT + 0.05)
	t:equal(r.actor(a).score, 1)
	r.run(r.schedule().endsAt + 0.1)
	t:equal(r.awards[a.player_id], Rules.prize(1))
	local paid = 0
	for _ in r.awards do paid += 1 end
	t:equal(paid, 1)
	local room = assert(Rules.results(assert(r.last(Rules.RESULTS, a))[1]))[1]
	for _, pl in room.placements do
		t:equal(pl.starlights, if pl.participant == r.id(a) then Rules.prize(1) else 0)
	end
end)

test.unit("bots are reproducible under a seed", function(t)
	local function trace(seed: number): string
		local r = round(2, seed)
		r.fight()
		r.run(r.schedule().playAt + 20)
		local out = {}
		for _, e in r.events(r.players[1]) do table.insert(out, e.kind .. "@" .. e.at) end
		return table.concat(out, ",")
	end
	t:equal(trace(5), trace(5))
	t:truthy(trace(5) ~= trace(6))
end)

test.unit("a reconnect keeps the seat; after the grace a bot takes it and the human forfeits", function(t)
	local r = round(4)
	local a, b = r.players[1], r.players[2]
	r.fight()
	t:equal(r.throw(a, b, 0.3), nil)
	r.run(r.now() + C.FLIGHT + 0.05)
	local id = r.id(b)
	r.send(b, Rules.CHARGE, "begin")
	r.game.leave(b :: any)
	t:truthy(not (r.actor(a, id).charging)) -- a held charge does not survive
	r.run(r.now() + C.RECONNECT - 1)
	local back: Player = { session_id = 99, player_id = b.player_id, isActive = true }
	r.players[2] = back
	r.game.join(back :: any)
	t:equal(r.snapshot(back).me, id)
	t:equal(r.actor(back).hp, C.HEARTS - 1)
	-- Gone for good: a labelled bot in the same seat with the same hearts, its own score.
	r.game.leave(back :: any)
	r.run(r.now() + C.RECONNECT + 0.1)
	local s = r.snapshot(a)
	t:truthy(s.participants[id].forfeited)
	local seat = s.participants[id].seat
	local replacement: Rules.Actor? = nil
	for _, actor in s.actors do if actor.seat == seat then replacement = actor end end
	t:truthy(replacement ~= nil and replacement.participant ~= id)
	local bot = s.participants[(replacement :: Rules.Actor).participant]
	t:truthy(bot.bot)
	t:equal(bot.draw, s.participants[id].draw)
	t:equal((replacement :: Rules.Actor).hp, C.HEARTS - 1)
	t:equal((replacement :: Rules.Actor).score, 0)
	-- The forfeited human cannot act and is listed under the results.
	r.game.join(back :: any)
	t:equal(r.snapshot(back).me, nil)
	r.run(r.schedule().endsAt + 0.1)
	local results = assert(Rules.results(assert(r.last(Rules.RESULTS, a))[1]))
	t:equal(results[1].forfeits[1], id)
	t:equal(#results[1].placements, 4)
	t:equal(r.awards[b.player_id], nil)
end)

test.unit("late arrivals watch room 1 and cannot act", function(t)
	local r = round(3)
	r.fight()
	local late: Player = { session_id = 77, player_id = 777, isActive = true }
	r.game.join(late :: any)
	local s = r.snapshot(late)
	t:equal(s.me, nil)
	t:equal(s.room, 1)
	r.game.receive(late :: any, Rules.CHARGE, 1, "begin")
	t:equal(r.last(Rules.REJECT, late), nil)
end)

test.unit("an aborted round pays nobody", function(t)
	local r = round(4)
	r.fight()
	r.run(r.now() + 10)
	r.game.finish() -- the cycle ended it early
	local results = assert(Rules.results(assert(r.last(Rules.RESULTS, r.players[1]))[1]))
	t:equal(results[1].status, "aborted")
	t:equal(results[1].winner, nil)
	t:equal(next(r.awards), nil)
end)
