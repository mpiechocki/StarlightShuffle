--!strict
-- Head to Head's rules (Rules) and its authoritative round (Server) driven
-- through a fake cycle context: who takes part, the pool, the shared
-- reference, tap validation, completion, ranking and disconnection.
local test = require("@moonbase/test")
local Rules = require("@project/minigames/head_to_head/Rules")
local Server = require("@project/minigames/head_to_head/Round")

type Player = { session_id: number, player_id: number, isActive: boolean, metadata: any?, arrival: any? }
type Sent = { to: {Player}?, kind: string, payload: any }

-- A fake cycle around one Head to Head round with [count] players.
local function round(count: number)
	local players: {Player} = {}
	for i = 1, count do players[i] = { session_id = 100 + i, player_id = 1000 + i, isActive = true } end
	local here = table.clone(players)
	local now, playEnds, starting = 0, 90, true
	local sent: {Sent} = {}
	local awards: {[number]: number} = {}
	local finished = 0
	local context: any = {
		game = { id = "head_to_head", title = "Head to Head", blurb = "", scene = "scene:head_to_head", duration = 90, intro = 10 },
		arena = nil,
		players = function() return here end,
		award = function(player: Player, n: number) awards[player.player_id] = (awards[player.player_id] or 0) + n end,
		send = function(to: {Player}?, kind: string, payload: any) table.insert(sent, { to = to, kind = kind, payload = payload }) end,
		clock = function() return now end,
		remaining = function() return if starting then 90 else math.max(0, playEnds - now) end,
		startsIn = function() return if starting then 10 else 0 end,
		identity = function(player: Player) return { session = player.session_id, player = player.player_id,
			name = "P" .. player.player_id, outfit = { 241120, -2 } } end,
		finish = function() finished += 1 end,
	}
	local game = Server.new(context)
	local fake = {}
	-- The last payload of [kind] sent to everyone, or to [player].
	function fake.last(kind: string, player: Player?): any
		for i = #sent, 1, -1 do
			local s = sent[i]
			if s.kind == kind and (s.to == nil or (player ~= nil and table.find(s.to, player) ~= nil)) then return s.payload end
		end
		return nil
	end
	function fake.setup(): Rules.Setup return assert(Rules.setup(fake.last(Rules.SETUP))) end
	function fake.reference(): {number}
		local setup = fake.setup()
		return assert(Rules.start(fake.last(Rules.START), #setup.pool)).reference
	end
	function fake.canvas(player: Player): Rules.Canvas
		return assert(Rules.canvas(fake.last(Rules.CANVAS, player), #fake.setup().pool))
	end
	function fake.start()
		starting = false
		game.start()
	end
	-- Taps [player]'s cells until their canvas matches the reference.
	function fake.solve(player: Player, from: number)
		local reference, size = fake.reference(), #fake.setup().pool
		local sequence = from
		local cells = fake.canvas(player).cells
		for cell = 1, Rules.CELLS do
			while cells[cell] ~= reference[cell] do
				sequence += 1
				game.receive(player, Rules.TAP, sequence, cell)
				cells[cell] = Rules.advance(cells[cell], size)
			end
		end
		return sequence
	end
	fake.players, fake.here, fake.game, fake.awards = players, here, game, awards
	fake.finished = function() return finished end
	fake.advance = function(seconds: number) now += seconds end
	fake.results = function(): {Rules.Place} return assert(Rules.results(fake.last(Rules.RESULTS))) end
	return fake
end

test.unit("the pool tops up to eight with distinct library heads", function(t)
	local three = round(3).setup()
	t:equal(#three.participants, 3)
	t:equal(#three.pool, 8)
	local players, library, seen = 0, 0, {}
	for _, entry in three.pool do
		local head = entry.head
		if head.kind == "player" then players += 1
		else
			library += 1
			t:truthy(not seen[head.library], "library heads are distinct")
			seen[head.library] = true
		end
	end
	t:equal(players, 3)
	t:equal(library, 5)
	local eight = round(8).setup()
	t:equal(#eight.pool, 8)
	for _, entry in eight.pool do t:equal(entry.head.kind, "player") end
	local ten = round(10).setup()
	t:equal(#ten.pool, 10)
	t:equal(#ten.participants, 10)
	-- Every head has its own outline colour.
	local colours = {}
	for _, entry in ten.pool do
		t:truthy(not colours[entry.color], "colours are distinct")
		colours[entry.color] = true
	end
end)

test.unit("taps count only during play, once per sequence and in order", function(t)
	local fake = round(2)
	local a = fake.players[1]
	-- Before play: refused, but answered.
	fake.game.receive(a, Rules.TAP, 1, 5)
	t:equal(fake.canvas(a).cells[5], 0)
	t:equal(fake.canvas(a).ack, 1)
	fake.start()
	t:equal(#fake.reference(), 9)
	fake.game.receive(a, Rules.TAP, 2, 5)
	t:equal(fake.canvas(a).cells[5], 1)
	-- A repeat or an older sequence does nothing.
	fake.game.receive(a, Rules.TAP, 2, 5)
	fake.game.receive(a, Rules.TAP, 1, 5)
	t:equal(fake.canvas(a).cells[5], 1)
	fake.game.receive(a, Rules.TAP, 3, 5)
	t:equal(fake.canvas(a).cells[5], 2)
	-- Bad cells are ignored.
	fake.game.receive(a, Rules.TAP, 4, 10)
	t:equal(fake.canvas(a).ack, 3)
	-- After the deadline, nothing changes.
	fake.advance(91)
	fake.game.receive(a, Rules.TAP, 5, 1)
	t:equal(fake.canvas(a).cells[1], 0)
end)

test.unit("tiles cycle through the pool and never back to empty", function(t)
	t:equal(Rules.advance(0, 8), 1)
	t:equal(Rules.advance(7, 8), 8)
	t:equal(Rules.advance(8, 8), 1)
end)

test.unit("a matching canvas completes, locks and ranks by server time", function(t)
	local fake = round(3)
	local a, b, c = fake.players[1], fake.players[2], fake.players[3]
	fake.start()
	fake.advance(20)
	local sa = fake.solve(a, 0)
	t:truthy(fake.canvas(a).done)
	t:equal(fake.canvas(a).time, 20)
	-- Locked: further taps change nothing.
	local before = table.clone(fake.canvas(a).cells)
	fake.game.receive(a, Rules.TAP, sa + 1, 1)
	t:equal(fake.canvas(a).cells[1], before[1])
	fake.advance(5)
	fake.solve(b, 0)
	t:equal(fake.finished(), 0, "the round goes on while someone is still matching")
	fake.advance(5)
	fake.solve(c, 0)
	t:equal(fake.finished(), 1, "everyone finished: play ends")
	fake.game.finish()
	local podium = fake.results()
	t:equal(#podium, 3)
	t:equal(podium[1].player, a.player_id)
	t:equal(podium[2].player, b.player_id)
	t:equal(podium[3].player, c.player_id)
	t:equal(fake.awards[a.player_id], Rules.AWARDS[1])
	t:equal(fake.awards[c.player_id], Rules.AWARDS[3])
end)

test.unit("only completed boards place, and equal times go by completion order", function(t)
	local fake = round(4)
	local a, b = fake.players[1], fake.players[2]
	fake.start()
	fake.advance(30)
	fake.solve(b, 0)
	fake.solve(a, 0) -- the same server time, but after b
	fake.game.finish()
	local podium = fake.results()
	t:equal(#podium, 2)
	t:equal(podium[1].player, b.player_id)
	t:equal(podium[2].player, a.player_id)
	t:equal(fake.awards[fake.players[3].player_id], nil)
end)

test.unit("a dropped player keeps their canvas and can finish on return", function(t)
	local fake = round(2)
	local a, b = fake.players[1], fake.players[2]
	fake.start()
	fake.game.receive(a, Rules.TAP, 1, 1)
	fake.game.leave(a)
	-- b finishing alone does not end it: a dropped player may come back...
	fake.solve(b, 0)
	t:equal(fake.finished(), 1, "every connected player is done")
	-- ...and a new connection for the same account carries on.
	local fake2 = round(2)
	local x, y = fake2.players[1], fake2.players[2]
	fake2.start()
	fake2.game.receive(x, Rules.TAP, 1, 1)
	local kept = fake2.canvas(x).cells[1]
	fake2.game.leave(x)
	local back = { session_id = 900, player_id = x.player_id, isActive = true }
	fake2.game.join(back)
	t:equal(fake2.canvas(back :: any).cells[1], kept)
	t:equal(fake2.canvas(back :: any).ack, 1)
	fake2.solve(back :: any, 1)
	t:truthy(fake2.canvas(back :: any).done)
	-- The old connection's taps no longer count.
	fake2.game.receive(x, Rules.TAP, 99, 2)
	fake2.solve(y, 0)
	fake2.game.finish()
	t:equal(fake2.results()[1].player, x.player_id)
end)

test.unit("latecomers watch: no canvas, no place", function(t)
	local fake = round(2)
	fake.start()
	local late = { session_id = 500, player_id = 5000, isActive = true }
	fake.game.join(late)
	t:equal(#fake.setup().participants, 2)
	fake.game.receive(late, Rules.TAP, 1, 1)
	t:equal(fake.last(Rules.CANVAS, late :: any), nil)
end)
