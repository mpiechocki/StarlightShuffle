--!strict
--@server
-- Star Pass's authoritative match on the cycle's server (see Rules for the
-- tuning and wire format; Server hands it the cycle's context).
--
-- When the cycle announces the mini-game (`new`), everyone here competes; the
-- roster is frozen and seated by account id, and later arrivals watch. When
-- the shared 10-second countdown ends, wave 1 starts: Rules.starCount stars go
-- to distinct survivors picked by an unbiased shuffle, and every star bursts at
-- the wave's one burstAt. A holder's intents name the star and its possession:
-- a charge begins, completes no sooner than CHARGE after the server saw it
-- begin, or is cancelled; a pass needs a completed charge, CATCH since the
-- catch, and a target among that star's current choices who is still free.
-- The first valid pass in server order wins; the loser is told (REJECT) and
-- nothing else changes. A pass hands the star over at once with a new
-- possession and no charge; it never moves the burst.
--
-- Everything due is settled before any intent is judged: at burstAt the
-- holders at that moment are all out together (ELIMINATED, one batch), stars
-- are cleared and the RECAP runs to nextWaveAt; then the next wave starts with
-- fewer stars. When one survivor is left, the final recap runs and the match
-- ends (context.finish). A competitor who stays disconnected FORFEIT seconds
-- forfeits: their star is removed, the wave keeps its burst, and a match left
-- with one competitor ends. Results rank survivors first, then later
-- eliminations, then passes, then seat; the top three take the podium.
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
}

type Competitor = {
	player: types.Player, id: number, seat: number, name: string, outfit: {number}?,
	alive: boolean, eliminatedWave: number?, passes: number,
	connected: boolean, leftAt: number?, sequence: number,
}
type Charge = { attempt: number, startedAt: number, completed: boolean }
type Star = { id: number, holder: number, previous: number?, possession: number, receivedAt: number, moveCount: number,
	charge: Charge?, choices: {number} }

return {
	new = function(context: Context): Round
		local startsAt = context.clock() + context.startsIn()
		local byId: {[number]: Competitor} = {}
		local seated: {Competitor} = {}
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
			for seat, id in ids do
				local player = players[id]
				local identity = context.identity(player)
				local c: Competitor = { player = player, id = id, seat = seat, name = if identity then identity.name else "Player " .. id,
					outfit = if identity then identity.outfit else nil, alive = true, eliminatedWave = nil, passes = 0,
					connected = true, leftAt = nil, sequence = 0 }
				byId[id], seated[seat] = c, c
			end
		end
		local phase: Rules.Phase = "countdown"
		local started = false
		local wave, burstAt, nextWaveAt = 0, 0, 0
		local stars: {Star} = {}
		local possessions, events, batches = 0, 0, 0
		local batch: Rules.Batch? = nil
		local finished, ended = false, false

		local function survivors(): {number}
			local out: {number} = {}
			for _, c in seated do if c.alive then table.insert(out, c.id) end end
			return out
		end

		local function holding(): {[number]: boolean}
			local out: {[number]: boolean} = {}
			for _, s in stars do out[s.holder] = true end
			return out
		end

		local function refresh(now: number)
			local alive, holders = survivors(), holding()
			for _, s in stars do
				s.choices = Rules.targets(alive, holders, s.holder, s.previous, now - s.receivedAt < C.RETURN, s.moveCount, wave, s.choices)
			end
		end

		local function starState(s: Star): Rules.Star
			return { id = s.id, holder = s.holder, previous = s.previous, possession = s.possession, receivedAt = s.receivedAt,
				moveCount = s.moveCount, charged = s.charge ~= nil and s.charge.completed, choices = s.choices }
		end

		local function starStates(): {Rules.Star}
			local out: {Rules.Star} = {}
			for _, s in stars do table.insert(out, starState(s)) end
			return out
		end

		local function snapshot(player: types.Player): types.Value
			local list: {Rules.Player} = {}
			for seat, c in seated do
				table.insert(list, { player = c.id, session = c.player.session_id, seat = seat, name = c.name, outfit = c.outfit,
					alive = c.alive, connected = c.connected, passes = c.passes, eliminatedWave = c.eliminatedWave })
			end
			local mine = byId[player.player_id]
			local charging: number? = nil
			if mine then
				for _, s in stars do
					if s.holder == mine.id and s.charge and not s.charge.completed then charging = s.charge.attempt end
				end
			end
			return Rules.snapshotValue({ version = Rules.VERSION, phase = phase, startsAt = startsAt, serverNow = context.clock(),
				wave = wave, burstAt = burstAt, nextWaveAt = nextWaveAt, players = list, stars = starStates(), batch = batch,
				lastEvent = events, lastSequence = if mine and mine.player == player then mine.sequence else 0, charging = charging })
		end

		local function broadcastSnapshots()
			for _, c in seated do
				if c.connected then context.send({c.player}, Rules.SNAPSHOT, snapshot(c.player)) end
			end
		end

		-- The match is over: once, through the cycle (its results follow).
		local function conclude()
			if ended then return end
			ended = true
			phase = "over"
			context.finish()
		end

		local function startWave(now: number)
			local alive = survivors()
			if #alive < 2 then conclude(); return end
			wave += 1
			-- An unbiased shuffle of the survivors; the first few hold stars.
			for i = #alive, 2, -1 do
				local j = math.floor(context.random() * i) + 1
				alive[i], alive[j] = alive[j], alive[i]
			end
			table.clear(stars)
			for i = 1, Rules.starCount(#alive) do
				possessions += 1
				table.insert(stars, { id = i, holder = alive[i], previous = nil, possession = possessions, receivedAt = now,
					moveCount = 0, charge = nil, choices = {} })
			end
			refresh(now)
			phase = "playing"
			burstAt = now + Rules.waveDuration(wave, context.random())
			events += 1
			context.send(nil, Rules.WAVE, Rules.waveValue({ event = events, wave = wave, startedAt = now, burstAt = burstAt, stars = starStates() }))
		end

		local function burst()
			-- Everyone holding a star at the burst, all at once.
			local out: {number} = {}
			for _, s in stars do
				local c = byId[s.holder]
				if c and c.alive then
					c.alive, c.eliminatedWave = false, wave
					table.insert(out, c.id)
				end
			end
			table.clear(stars)
			local left = #survivors()
			batches += 1
			nextWaveAt = burstAt + C.RECAP
			batch = { id = batches, wave = wave, players = out, at = burstAt, nextAt = nextWaveAt, survivors = left, final = left <= 1 }
			phase = "recap"
			events += 1
			context.send(nil, Rules.ELIMINATED, events, Rules.batchValue(batch :: Rules.Batch))
		end

		local function forfeit(c: Competitor, now: number)
			if not c.alive then return end
			c.alive, c.eliminatedWave = false, math.max(1, wave)
			for i = #stars, 1, -1 do
				if stars[i].holder == c.id then table.remove(stars, i) end
			end
			refresh(now)
			broadcastSnapshots()
			if (phase == "playing" or phase == "recap") and #survivors() <= 1 and not (batch and batch.final) then conclude() end
		end

		-- Settles everything due by [now]: the start, bursts, recaps, forfeits.
		local function settle(now: number)
			if not started or ended then return end
			for _, c in seated do
				if not c.connected and c.alive and c.leftAt and now - c.leftAt >= C.FORFEIT then forfeit(c, now) end
			end
			if ended then return end
			if phase == "countdown" and now >= startsAt then startWave(startsAt) end
			if phase == "playing" and now >= burstAt then burst() end
			if phase == "recap" and now >= nextWaveAt then
				if batch and batch.final then conclude() else startWave(nextWaveAt) end
			end
		end

		local function starFor(c: Competitor, id: number, possession: number): (Star?, string)
			if phase ~= "playing" then return nil, "phase" end
			if not c.alive then return nil, "out" end
			for _, s in stars do
				if s.id == id then
					if s.holder ~= c.id then return nil, "holder" end
					if s.possession ~= possession then return nil, "stale" end
					return s, ""
				end
			end
			return nil, "star"
		end

		local function charge(c: Competitor, sequence: number, op: string, id: number, possession: number, attempt: number, now: number)
			local function reply(status: string, reason: string)
				context.send({c.player}, Rules.CHARGED, Rules.chargedValue({ sequence = sequence, star = id, possession = possession,
					attempt = attempt, status = status :: any, reason = reason }))
			end
			local s, reason = starFor(c, id, possession)
			if not s or now >= burstAt then reply("rejected", if s then "burst" else reason); return end
			local current = s.charge
			if op == "begin" then
				if current and current.completed then reply("charged", ""); return end
				s.charge = { attempt = attempt, startedAt = now, completed = false }
				reply("started", "")
			elseif op == "cancel" then
				if current and current.attempt == attempt and not current.completed then
					s.charge = nil
					reply("cancelled", "")
				else
					reply("rejected", "stale")
				end
			else -- complete
				if not current or current.attempt ~= attempt then reply("rejected", "stale"); return end
				if current.completed then reply("charged", ""); return end
				if now - current.startedAt < C.CHARGE - C.SLACK then reply("rejected", "early"); return end
				current.completed = true
				reply("charged", "")
			end
		end

		local function pass(c: Competitor, sequence: number, id: number, possession: number, target: number, now: number)
			local s, reason = starFor(c, id, possession)
			local to = byId[target]
			local why = if not s then reason
				elseif now >= burstAt then "burst"
				elseif not (s.charge and s.charge.completed) then "charge"
				elseif now - s.receivedAt < C.CATCH - C.SLACK then "catch"
				elseif not table.find(s.choices, target) then "target"
				elseif not to or not to.alive or holding()[target] or target == c.id then "target"
				else nil
			if why or not s then
				context.send({c.player}, Rules.REJECT, sequence, why or reason)
				return
			end
			possessions += 1
			s.previous, s.holder, s.possession, s.receivedAt = c.id, target, possessions, now
			s.moveCount += 1
			s.charge = nil
			s.choices = {}
			c.passes += 1
			refresh(now)
			events += 1
			context.send(nil, Rules.PASSED, Rules.passedValue({ event = events, star = s.id, from = c.id, to = target,
				possession = s.possession, at = now, passes = c.passes, stars = starStates() }))
		end

		context.send(nil, Rules.SNAPSHOT, snapshot({ session_id = 0, player_id = -1, isActive = true } :: any))

		return {
			start = function()
				started = true
				settle(context.clock())
			end,
			update = function(_dt: number)
				settle(context.clock())
			end,
			join = function(player: types.Player)
				local c = byId[player.player_id]
				if c then c.player, c.connected, c.leftAt = player, true, nil end
				context.send({player}, Rules.SNAPSHOT, snapshot(player))
				if c then broadcastSnapshots() end
			end,
			leave = function(player: types.Player)
				local c = byId[player.player_id]
				if not c or c.player ~= player then return end
				c.connected, c.leftAt = false, context.clock()
				broadcastSnapshots()
			end,
			receive = function(player: types.Player, kind: unknown, ...: unknown)
				local a, b, cc, d, e = ...
				if kind == Rules.SYNC then
					if type(a) == "number" and a == a then context.send({player}, Rules.SYNC, a, Rules.ms(context.clock())) end
					return
				end
				local c = byId[player.player_id]
				if not c or c.player ~= player then return end
				local now = context.clock()
				-- Anything due happens before this intent is judged.
				settle(now)
				if kind == Rules.CHARGE then
					local sequence, op, id, possession, attempt = Rules.chargeIntent(a, b, cc, d, e)
					if not sequence or sequence <= c.sequence then return end
					c.sequence = sequence
					charge(c, sequence, op :: string, id :: number, possession :: number, attempt :: number, now)
				elseif kind == Rules.PASS then
					local sequence, id, possession, target = Rules.passIntent(a, b, cc, d)
					if not sequence or sequence <= c.sequence then return end
					c.sequence = sequence
					pass(c, sequence, id :: number, possession :: number, target :: number, now)
				end
			end,
			finish = function()
				if finished then return end
				finished, ended = true, true
				phase = "over"
				local entries: {Rules.Competitor} = {}
				for _, c in seated do
					table.insert(entries, { player = c.id, seat = c.seat, alive = c.alive, eliminatedWave = c.eliminatedWave, passes = c.passes })
				end
				local standings: {Rules.Standing} = {}
				-- Nobody wins a match that never had two competitors.
				local competed = #seated >= 2
				for place, entry in Rules.rank(entries) do
					local c = byId[entry.player]
					local starlights = if competed then Standings.prize(place) else 0
					table.insert(standings, { player = c.id, name = c.name, place = place, passes = c.passes,
						wave = c.eliminatedWave, starlights = starlights })
					if starlights > 0 and c.connected then context.award(c.player, starlights) end
				end
				context.send(nil, Rules.RESULTS, Rules.standingsValue(standings))
			end,
		}
	end,
}
