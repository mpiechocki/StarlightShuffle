--!strict
--@server
-- Starcatchers' authoritative round on the cycle's server (see Rules for the
-- tuning, physics and wire format; Server hands it the cycle's context).
--
-- When the cycle announces the mini-game (`new`), everyone here competes: the
-- roster is frozen, seated by account id (a seat is its stream of stars), the
-- match seed drawn and the roster shuffled into one wrapping lineup. Later
-- arrivals watch the first player in the lineup.
--
-- Every net is simulated here, on its own stream, all through the round:
-- before an intent is judged and on every tick, each net is stepped to now
-- (catches, satellite hits and banks happen at their exact substep). A throw
-- needs an idle, untangled net during play; a release recalls a rising one.
-- Whenever a net changes (a throw, a recall, the top of a throw, a catch, a
-- bank, a hit, the end of a tangle), its new state goes to its player (with
-- the stars they used up) and to everyone who shows it: the two neighbours
-- and up to six players further along the lineup. A player who leaves has a
-- flying net recalled, and keeps everything on return.
--
-- At the end every unscored catch is dropped; standings use the shared tie
-- policy (points, then who reached them first, then id) and the top three
-- still here, with at least one point, take the podium's Starlights.
local types = require("@moonbase/types")
local Rules = require("./Rules")
local Standings = require("../../shared/Standings")

local C = Rules.CONFIG

export type Context = {
	players: () -> {types.Player},
	award: (player: types.Player, starlights: number) -> (),
	send: (players: {types.Player}?, ...types.Value) -> (),
	clock: () -> number,
	startsIn: () -> number,
	identity: (player: types.Player) -> { name: string, outfit: {number}? }?,
	random: () -> number,
	finish: () -> (),
}
export type Round = {
	start: () -> (),
	join: (player: types.Player) -> (),
	leave: (player: types.Player) -> (),
	receive: (player: types.Player, kind: unknown, ...unknown) -> (),
	update: (dt: number) -> (),
	finish: () -> (),
	-- For tests: [id]'s net as the server has it.
	net: (id: number) -> Rules.Net?,
	seed: number,
}

type Competitor = {
	player: types.Player, id: number, stream: number, name: string, outfit: {number}?,
	net: Rules.Net, version: number, connected: boolean, sequence: number,
	-- Players who show this net (besides its owner), by session.
	watchers: {[number]: types.Player},
}

return {
	new = function(context: Context): Round
		local startsAt = context.clock() + context.startsIn()
		local seed = math.floor(context.random() * 2147483647)
		local byId: {[number]: Competitor} = {}
		local seated: {Competitor} = {}
		local spectators: {[number]: types.Player} = {}
		do
			local ids: {number} = {}
			local players: {[number]: types.Player} = {}
			for _, player in context.players() do
				if not players[player.player_id] then
					players[player.player_id] = player
					table.insert(ids, player.player_id)
				end
			end
			table.sort(ids)
			for stream, id in ids do
				local player = players[id]
				local identity = context.identity(player)
				local c: Competitor = { player = player, id = id, stream = stream, name = if identity then identity.name else "Player " .. id,
					outfit = if identity then identity.outfit else nil, net = Rules.newNet(), version = 0, connected = true, sequence = 0,
					watchers = {} }
				byId[id], seated[stream] = c, c
			end
		end
		local lineup: {number} = {}
		for _, c in seated do table.insert(lineup, c.id) end
		Rules.shuffle(lineup, context.random)
		local finished, ending = false, false

		-- Whose nets [id] shows: their own, the neighbours and the distant few.
		local function shown(id: number): {number}
			local out = { id }
			local left, right = Rules.neighbours(lineup, id)
			if left then table.insert(out, left) end
			if right then table.insert(out, right) end
			for _, d in Rules.distant(lineup, id) do table.insert(out, d.player) end
			return out
		end

		local function watch(viewer: types.Player, as: number)
			for _, id in shown(as) do
				local c = byId[id]
				if c and c.player ~= viewer then c.watchers[viewer.session_id] = viewer end
			end
		end
		for _, c in seated do watch(c.player, c.id) end

		local function snapshot(viewer: types.Player): types.Value
			local mine = byId[viewer.player_id]
			if mine and mine.player ~= viewer then mine = nil end
			local as = if mine then mine.id else lineup[1]
			local participants: {Rules.Participant} = {}
			for _, c in seated do
				table.insert(participants, { player = c.id, session = c.player.session_id, name = c.name, outfit = c.outfit, stream = c.stream })
			end
			local nets: {Rules.Update} = {}
			if as then
				for _, id in shown(as) do
					local c = byId[id]
					if c then table.insert(nets, { player = c.id, version = c.version, net = c.net }) end
				end
			end
			return Rules.snapshotValue({ version = Rules.VERSION, seed = seed, startsAt = startsAt, serverNow = context.clock(),
				lineup = lineup, participants = participants, nets = nets, lastSequence = if mine then mine.sequence else 0 },
				if mine then mine.id else nil)
		end

		-- [c]'s net changed: to its owner (with what they used up) and its watchers.
		local function publish(c: Competitor, event: Rules.Event?)
			c.version += 1
			local update: Rules.Update = { player = c.id, version = c.version, net = c.net, event = event }
			if c.connected then context.send({c.player}, Rules.NET, Rules.updateValue(update, true)) end
			local others: {types.Player} = {}
			for _, viewer in c.watchers do
				if viewer.isActive then table.insert(others, viewer) end
			end
			if #others > 0 then context.send(others, Rules.NET, Rules.updateValue(update, false)) end
		end

		-- Moves [c]'s net on to [elapsed], publishing what changed on the way.
		local function advance(c: Competitor, elapsed: number)
			local before = c.net.stage
			local events: {Rules.Event} = {}
			Rules.step(c.net, elapsed, seed, c.stream, function(e: Rules.Event) table.insert(events, e) end)
			for _, e in events do publish(c, e) end
			if #events == 0 and c.net.stage ~= before then publish(c, nil) end
		end

		local function conclude()
			if ending then return end
			ending = true
			context.finish()
		end

		local started = false
		local function settle(now: number)
			if not started or finished then return end
			local elapsed = now - startsAt
			if elapsed <= 0 then return end
			for _, c in seated do advance(c, elapsed) end
			if elapsed >= C.DURATION then conclude() end
		end

		for _, c in seated do context.send({c.player}, Rules.SNAPSHOT, snapshot(c.player)) end

		return {
			seed = seed,
			start = function()
				started = true
				settle(context.clock())
			end,
			update = function(_dt: number)
				settle(context.clock())
			end,
			join = function(player: types.Player)
				local c = byId[player.player_id]
				if c then
					-- Back: the same seat, net and score.
					c.player, c.connected = player, true
					watch(player, c.id)
				else
					spectators[player.session_id] = player
					if lineup[1] then watch(player, lineup[1]) end
				end
				context.send({player}, Rules.SNAPSHOT, snapshot(player))
			end,
			leave = function(player: types.Player)
				spectators[player.session_id] = nil
				for _, c in seated do c.watchers[player.session_id] = nil end
				local c = byId[player.player_id]
				if not c or c.player ~= player then return end
				c.connected = false
				-- A net in the air comes home on its own.
				local elapsed = context.clock() - startsAt
				if started and not finished then
					advance(c, elapsed)
					if Rules.recall(c.net, elapsed) then publish(c, nil) end
				end
			end,
			receive = function(player: types.Player, kind: unknown, a: unknown)
				if kind == Rules.SYNC then
					if type(a) == "number" and a == a then context.send({player}, Rules.SYNC, a, Rules.ms(context.clock())) end
					return
				end
				local c = byId[player.player_id]
				if not c or c.player ~= player then return end
				local sequence = Rules.sequence(a)
				if not sequence or sequence <= c.sequence then return end
				c.sequence = sequence
				local now = context.clock()
				-- Everything due happens before this intent is judged.
				settle(now)
				if not started or finished then
					if kind == Rules.THROW then context.send({player}, Rules.REJECT, sequence) end
					return
				end
				local elapsed = now - startsAt
				if kind == Rules.THROW then
					if Rules.throw(c.net, elapsed) then publish(c, nil) else context.send({player}, Rules.REJECT, sequence) end
				elseif kind == Rules.RECALL then
					if Rules.recall(c.net, elapsed) then publish(c, nil) end
				end
			end,
			finish = function()
				if finished then return end
				ending = true -- settling now must not end the round a second time
				settle(context.clock())
				finished = true
				local scores: {Standings.Score} = {}
				for _, c in seated do
					Rules.step(c.net, C.DURATION) -- whatever is still in the air is dropped
					table.insert(scores, { player = c.id, name = c.name, score = c.net.score, reachedAt = c.net.reachedAt })
				end
				local standings: {Rules.Standing} = {}
				for place, s in Standings.rank(scores) do
					-- A podium place needs at least one star brought home.
					local starlights = if s.score > 0 then Standings.prize(place) else 0
					table.insert(standings, { player = s.player, name = s.name, place = place, score = s.score, starlights = starlights })
					local c = byId[s.player]
					-- Prizes go to winners still here to receive them.
					if starlights > 0 and c.connected then context.award(c.player, starlights) end
				end
				context.send(nil, Rules.RESULTS, Rules.standingsValue(standings))
			end,
			net = function(id: number): Rules.Net?
				local c = byId[id]
				return if c then c.net else nil
			end,
		}
	end,
}
