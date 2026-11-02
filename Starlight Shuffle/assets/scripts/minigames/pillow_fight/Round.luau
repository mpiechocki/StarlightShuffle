--!strict
--@server
-- Pillow Fight's authoritative round on the cycle's server (see Rules for the
-- tuning and wire format; Server hands it the cycle's context).
--
-- When the cycle announces the mini-game (`new`), everyone here is the frozen
-- roster: the humans are grouped (Rules.assign), filler bots take the empty
-- slots, and every participant draws a unique tie-break ticket from one
-- shuffle. Later arrivals watch room 1. The schedule follows the
-- announcement: the group reveal (several rooms only), the countdown, then
-- PLAY seconds of fighting; at endsAt the round ends itself (context.finish).
--
-- Intents act on the sender's seat and are judged on the server's clock after
-- everything due by then has happened: a throw needs a charge the server saw
-- begin at least MIN_CHARGE earlier (FULL_CHARGE for two hearts; past
-- MAX_CHARGE it was already cancelled), a living rival in the same room and
-- the cooldown; a dodge opens DODGE_WINDOW. Impacts resolve in time order
-- (then pillow id): a knocked-out or replaced target is missed, spawn
-- protection and a dodge window covering the impact block it, otherwise it
-- hits (+1, and +3 for the knockout). Pillows landing at or after endsAt do
-- nothing. Bots act through the same checks.
--
-- A human who stays disconnected RECONNECT seconds forfeits: a labelled bot
-- takes their seat with its hearts and cooldowns, their draw ticket and a
-- score of its own. Results: each room's seat holders by Rules.compare, one
-- winner who (if a connected human) gets WINNER_STARLIGHTS; a room whose
-- humans all left, or a round that never reached endsAt, is aborted.
local types = require("@moonbase/types")
local Rules = require("./Rules")

local C = Rules.CONFIG
local B = C.BOT

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
	-- For tests: the room [player] fights in and its seats, as sent.
	inspect: (player: types.Player) -> (number?, {Rules.Actor}),
}

type Participant = {
	id: number, bot: boolean, player: types.Player?, name: string, outfit: {number}?, doll: number?,
	room: number, seat: number, draw: number, connected: boolean, leftAt: number?, forfeited: boolean,
	sequence: number, rateWindow: number, rateCount: number,
	score: number, hits: number, kos: number, deaths: number,
}
type Brain = { nextThink: number, holdFor: number, dodgeAt: number?, considered: {[number]: boolean} }
type Seat = {
	room: number, seat: number, holder: Participant, hp: number, chargeStartedAt: number?,
	throwReadyAt: number, dodgeAt: number, dodgeUntil: number, dodgeReadyAt: number, stunnedUntil: number,
	respawnAt: number, protectedUntil: number, brain: Brain,
}
type Room = { index: number, seats: {Seat}, projectiles: {Rules.Projectile}, events: number }

return {
	new = function(context: Context): Round
		local participants: {Participant} = {}
		local byAccount: {[number]: Participant} = {}
		local rooms: {Room} = {}
		local spectators: {[number]: types.Player} = {} -- by session
		local bots, shots = 0, 0
		local started, ending, finished = false, false, false

		local function newBrain(): Brain
			return { nextThink = 0, holdFor = B.HOLD, dodgeAt = nil, considered = {} }
		end

		local function makeBot(room: number, seat: number, draw: number): Participant
			bots += 1
			local bot: Participant = { id = #participants + 1, bot = true, player = nil,
				name = Rules.BOT_NAMES[(bots - 1) % #Rules.BOT_NAMES + 1] .. " · bot", outfit = nil, doll = (bots - 1) % Rules.DOLLS + 1,
				room = room, seat = seat, draw = draw, connected = true, leftAt = nil, forfeited = false,
				sequence = 0, rateWindow = 0, rateCount = 0, score = 0, hits = 0, kos = 0, deaths = 0 }
			table.insert(participants, bot)
			return bot
		end

		do
			local humans: {number} = {}
			local players: {[number]: types.Player} = {}
			for _, player in context.players() do
				if not players[player.player_id] then
					players[player.player_id] = player
					table.insert(humans, player.player_id)
				end
			end
			table.sort(humans)
			local plan = Rules.groupPlan(#humans)
			for index, members in Rules.assign(humans, context.random) do
				local room: Room = { index = index, seats = {}, projectiles = {}, events = 0 }
				for seat = 1, plan[index] do
					local holder: Participant
					local account = members[seat]
					if account then
						local player = players[account]
						local identity = context.identity(player)
						local human: Participant = { id = #participants + 1, bot = false, player = player,
							name = if identity then identity.name else "Player " .. account, outfit = if identity then identity.outfit else nil,
							doll = nil, room = index, seat = seat, draw = 0, connected = true, leftAt = nil, forfeited = false,
							sequence = 0, rateWindow = 0, rateCount = 0, score = 0, hits = 0, kos = 0, deaths = 0 }
						holder = human
						table.insert(participants, holder)
						byAccount[account] = holder
					else
						holder = makeBot(index, seat, 0)
					end
					room.seats[seat] = { room = index, seat = seat, holder = holder, hp = C.HEARTS, chargeStartedAt = nil,
						throwReadyAt = 0, dodgeAt = 0, dodgeUntil = 0, dodgeReadyAt = 0, stunnedUntil = 0, respawnAt = 0,
						protectedUntil = 0, brain = newBrain() }
				end
				rooms[index] = room
			end
			-- One shuffle of every occupied slot: the immutable last tie-break.
			local order = table.clone(participants)
			Rules.shuffle(order, context.random)
			for draw, pt in order do pt.draw = draw end
		end
		local schedule = Rules.schedule(context.clock() + context.startsIn(), math.max(1, #rooms))

		local function seatOf(pt: Participant): Seat?
			local room = rooms[pt.room]
			local seat = if room then room.seats[pt.seat] else nil
			return if seat and seat.holder == pt then seat else nil
		end

		local function actorOf(seat: Seat): Rules.Actor
			local h = seat.holder
			return { seat = seat.seat, participant = h.id, hp = seat.hp, score = h.score, hits = h.hits, kos = h.kos, deaths = h.deaths,
				charging = seat.chargeStartedAt ~= nil, throwReadyAt = seat.throwReadyAt, dodgeAt = seat.dodgeAt, dodgeUntil = seat.dodgeUntil,
				dodgeReadyAt = seat.dodgeReadyAt, stunnedUntil = seat.stunnedUntil, respawnAt = seat.respawnAt,
				protectedUntil = seat.protectedUntil }
		end

		-- Who sees [room]: its connected humans, and the watchers of room 1.
		local function audience(room: Room): {types.Player}
			local out: {types.Player} = {}
			for _, seat in room.seats do
				local h = seat.holder
				if not h.bot and h.connected and h.player then table.insert(out, h.player) end
			end
			if room.index == 1 then
				for _, player in spectators do table.insert(out, player) end
			end
			return out
		end

		local function emit(room: Room, kind: Rules.EventKind, at: number, seats: {Seat}, projectile: Rules.Projectile?)
			room.events += 1
			local actors: {Rules.Actor} = {}
			for _, seat in seats do table.insert(actors, actorOf(seat)) end
			local to = audience(room)
			if #to > 0 then
				context.send(to, Rules.EVENT, Rules.eventValue({ event = room.events, room = room.index, kind = kind, at = at, actors = actors,
					projectile = projectile }))
			end
		end

		local function snapshot(player: types.Player): types.Value
			local mine = byAccount[player.player_id]
			if mine and (mine.forfeited or mine.player ~= player) then mine = nil end
			local room = rooms[if mine then mine.room else 1]
			local list: {Rules.Participant} = {}
			for _, pt in participants do
				table.insert(list, { id = pt.id, name = pt.name, bot = pt.bot, outfit = pt.outfit, doll = pt.doll, room = pt.room, seat = pt.seat,
					draw = pt.draw, forfeited = pt.forfeited, account = if pt.player then pt.player.player_id else nil })
			end
			local actors: {Rules.Actor} = {}
			if room then for _, seat in room.seats do table.insert(actors, actorOf(seat)) end end
			return Rules.snapshotValue({ version = Rules.VERSION, startsAt = schedule.startsAt, playAt = schedule.playAt, endsAt = schedule.endsAt,
				rooms = schedule.rooms, serverNow = context.clock(), participants = list, me = if mine then mine.id else nil,
				room = if room then room.index else 1, actors = actors, projectiles = if room then room.projectiles else {},
				lastEvent = if room then room.events else 0, lastSequence = if mine then mine.sequence else 0 })
		end

		local function broadcastSnapshots()
			for _, pt in participants do
				if not pt.bot and pt.connected and not pt.forfeited and pt.player then
					context.send({pt.player}, Rules.SNAPSHOT, snapshot(pt.player))
				end
			end
			for _, player in spectators do context.send({player}, Rules.SNAPSHOT, snapshot(player)) end
		end

		local function playing(now: number): boolean
			return started and not finished and now >= schedule.playAt and now < schedule.endsAt
		end

		local function cancelCharge(seat: Seat, at: number)
			if seat.chargeStartedAt then
				seat.chargeStartedAt = nil
				emit(rooms[seat.room], "cancel", at, {seat})
			end
		end

		-- The actions, for humans and bots alike: nil when done, else why not.
		local function beginCharge(seat: Seat, now: number): string?
			if not playing(now) then return "phase" end
			if seat.respawnAt ~= 0 then return "out" end
			if seat.chargeStartedAt then return "charging" end
			if now < seat.stunnedUntil then return "stun" end
			if now < seat.throwReadyAt then return "cooldown" end
			seat.chargeStartedAt = now
			emit(rooms[seat.room], "charge", now, {seat})
			return nil
		end

		local function throw(seat: Seat, target: number, now: number): string?
			if not playing(now) then return "phase" end
			if seat.respawnAt ~= 0 then return "out" end
			local startedAt = seat.chargeStartedAt
			if not startedAt then return "charge" end
			local held = now - startedAt
			local room = rooms[seat.room]
			local to: Seat? = nil
			for _, other in room.seats do
				if other.holder.id == target and other ~= seat then to = other end
			end
			local why = if held < C.MIN_CHARGE then "short"
				elseif held > C.MAX_CHARGE then "long"
				elseif now < seat.stunnedUntil then "stun"
				elseif now < seat.throwReadyAt then "cooldown"
				elseif not to or to.respawnAt ~= 0 then "target"
				else nil
			if why then
				cancelCharge(seat, now)
				return why
			end
			seat.chargeStartedAt = nil
			seat.throwReadyAt = now + C.THROW_COOLDOWN
			shots += 1
			local shot: Rules.Projectile = { id = shots, from = seat.holder.id, to = target, startedAt = now, impactAt = now + C.FLIGHT,
				power = if held >= C.FULL_CHARGE then 2 else 1 }
			table.insert(room.projectiles, shot)
			emit(room, "throw", now, {seat}, shot)
			return nil
		end

		local function dodge(seat: Seat, now: number): string?
			if not playing(now) then return "phase" end
			if seat.respawnAt ~= 0 then return "out" end
			if now < seat.stunnedUntil then return "stun" end
			if now < seat.dodgeReadyAt then return "cooldown" end
			seat.chargeStartedAt = nil
			seat.dodgeAt, seat.dodgeUntil, seat.dodgeReadyAt = now, now + C.DODGE_WINDOW, now + C.DODGE_COOLDOWN
			emit(rooms[seat.room], "dodge", now, {seat})
			return nil
		end

		local function respawn(room: Room, seat: Seat)
			local at = seat.respawnAt
			seat.respawnAt, seat.hp, seat.protectedUntil = 0, C.HEARTS, at + C.SPAWN_PROTECTION
			emit(room, "respawn", at, {seat})
		end

		local function impact(room: Room, shot: Rules.Projectile)
			local at = shot.impactAt
			local to: Seat?, from: Seat? = nil, nil
			for _, seat in room.seats do
				if seat.holder.id == shot.to then to = seat end
				if seat.holder.id == shot.from then from = seat end
			end
			local sender = participants[shot.from]
			if not to or not sender or to.respawnAt ~= 0 then
				emit(room, "fizzle", at, {}, shot)
				return
			end
			local target = to :: Seat
			if at <= target.protectedUntil then emit(room, "blocked", at, {target}, shot); return end
			if target.dodgeAt <= at and at <= target.dodgeUntil then emit(room, "miss", at, {target}, shot); return end
			target.hp = math.max(0, target.hp - shot.power)
			target.chargeStartedAt = nil
			target.stunnedUntil = at + C.STUN
			sender.hits += 1
			sender.score += C.HIT_SCORE
			local kind: Rules.EventKind = "hit"
			if target.hp == 0 then
				kind = "ko"
				target.holder.deaths += 1
				sender.kos += 1
				sender.score += C.KO_SCORE
				target.respawnAt = at + C.RESPAWN
			end
			local changed = {target}
			if from and from ~= target then table.insert(changed, from :: Seat) end
			emit(room, kind, at, changed, shot)
		end

		-- Respawns and impacts due by [limit], in time order (pillows by id on ties).
		local function resolve(room: Room, limit: number)
			while true do
				local nextSeat: Seat? = nil
				for _, seat in room.seats do
					if seat.respawnAt ~= 0 and seat.respawnAt <= limit and (not nextSeat or seat.respawnAt < nextSeat.respawnAt) then nextSeat = seat end
				end
				local nextShot: Rules.Projectile? = nil
				for _, shot in room.projectiles do
					if shot.impactAt <= limit and shot.impactAt < schedule.endsAt
						and (not nextShot or shot.impactAt < nextShot.impactAt or (shot.impactAt == nextShot.impactAt and shot.id < nextShot.id)) then
						nextShot = shot
					end
				end
				if nextSeat and (not nextShot or nextSeat.respawnAt <= nextShot.impactAt) then
					respawn(room, nextSeat)
				elseif nextShot then
					local at = table.find(room.projectiles, nextShot)
					if at then table.remove(room.projectiles, at) end
					impact(room, nextShot)
				else
					break
				end
			end
		end

		local function replace(pt: Participant, now: number)
			local seat = seatOf(pt)
			pt.forfeited, pt.connected = true, false
			if not seat then return end
			seat.chargeStartedAt = nil
			local bot = makeBot(pt.room, pt.seat, pt.draw)
			seat.holder, seat.brain = bot, newBrain()
			seat.brain.nextThink = now + B.THINK
			-- Pillows already flying at the seat land on whoever sits there.
			for _, shot in rooms[pt.room].projectiles do
				if shot.to == pt.id then shot.to = bot.id end
			end
			broadcastSnapshots()
		end

		local function think(room: Room, seat: Seat, now: number)
			local brain = seat.brain
			-- A pillow in flight at the bot: sometimes it plans a dodge (late ones fail).
			for _, shot in room.projectiles do
				if shot.to == seat.holder.id and not brain.considered[shot.id] then
					brain.considered[shot.id] = true
					if context.random() < B.DODGE then
						brain.dodgeAt = shot.impactAt - (B.DODGE_LEAD + context.random() * B.DODGE_LEAD_SPREAD)
					end
				end
			end
			if brain.dodgeAt and now >= brain.dodgeAt then
				brain.dodgeAt = nil
				dodge(seat, now)
			end
			if now < brain.nextThink then return end
			brain.nextThink = now + B.THINK + context.random() * B.THINK_JITTER
			if seat.respawnAt ~= 0 or now < seat.stunnedUntil then return end
			local startedAt = seat.chargeStartedAt
			if startedAt then
				if now - startedAt >= brain.holdFor then
					local rivals: {number} = {}
					for _, other in room.seats do
						if other ~= seat and other.respawnAt == 0 then table.insert(rivals, other.holder.id) end
					end
					if #rivals > 0 then
						throw(seat, rivals[math.min(#rivals, math.floor(context.random() * #rivals) + 1)], now)
					else
						cancelCharge(seat, now)
					end
				end
			elseif now >= seat.throwReadyAt and context.random() < B.START then
				brain.holdFor = B.HOLD + context.random() * B.HOLD_SPREAD
				beginCharge(seat, now)
			end
		end

		local function conclude()
			if ending then return end
			ending = true
			context.finish()
		end

		-- Everything due by [now]: respawns, impacts, held-too-long charges,
		-- forfeits, the bots' moves and the end of the round.
		local function settle(now: number)
			if not started or finished then return end
			for _, pt in participants do
				if not pt.bot and not pt.forfeited and not pt.connected and pt.leftAt and now - pt.leftAt >= C.RECONNECT then replace(pt, now) end
			end
			local limit = math.min(now, schedule.endsAt)
			for _, room in rooms do
				resolve(room, limit)
				if playing(now) then
					for _, seat in room.seats do
						local startedAt = seat.chargeStartedAt
						if startedAt and now - startedAt > C.MAX_CHARGE then cancelCharge(seat, now) end
					end
					for _, seat in room.seats do
						if seat.holder.bot then think(room, seat, now) end
					end
				end
			end
			if now >= schedule.endsAt then conclude() end
		end

		local function allowed(pt: Participant, now: number): boolean
			if now - pt.rateWindow >= 1 then pt.rateWindow, pt.rateCount = now, 0 end
			pt.rateCount += 1
			return pt.rateCount <= C.RATE
		end

		if #rooms > 0 then
			for _, room in rooms do
				for _, seat in room.seats do seat.brain.nextThink = schedule.playAt + context.random() * 0.6 end
			end
		end
		broadcastSnapshots()

		return {
			start = function()
				started = true
				settle(context.clock())
			end,
			update = function(_dt: number)
				settle(context.clock())
			end,
			join = function(player: types.Player)
				local pt = byAccount[player.player_id]
				if pt and not pt.forfeited then
					pt.player, pt.connected, pt.leftAt = player, true, nil
				else
					spectators[player.session_id] = player
				end
				context.send({player}, Rules.SNAPSHOT, snapshot(player))
			end,
			leave = function(player: types.Player)
				spectators[player.session_id] = nil
				local pt = byAccount[player.player_id]
				if not pt or pt.player ~= player or pt.forfeited then return end
				pt.connected, pt.leftAt = false, context.clock()
				local seat = seatOf(pt)
				if seat then cancelCharge(seat, context.clock()) end
			end,
			receive = function(player: types.Player, kind: unknown, a: unknown, b: unknown)
				if kind == Rules.SYNC then
					if type(a) == "number" and a == a then context.send({player}, Rules.SYNC, a, Rules.ms(context.clock())) end
					return
				end
				local pt = byAccount[player.player_id]
				if not pt or pt.player ~= player or pt.forfeited then return end
				local now = context.clock()
				if not allowed(pt, now) then return end
				-- Anything due happens before this intent is judged.
				settle(now)
				local seat = seatOf(pt)
				if not seat then return end
				local sequence: number?, why: string? = nil, nil
				if kind == Rules.CHARGE then
					local op: string?
					sequence, op = Rules.chargeIntent(a, b)
					if not sequence or sequence <= pt.sequence then return end
					pt.sequence = sequence
					if op == "begin" then why = beginCharge(seat, now)
					elseif seat.chargeStartedAt then cancelCharge(seat, now) end
				elseif kind == Rules.THROW then
					local target: number?
					sequence, target = Rules.throwIntent(a, b)
					if not sequence or sequence <= pt.sequence then return end
					pt.sequence = sequence
					why = throw(seat, target :: number, now)
				elseif kind == Rules.DODGE then
					sequence = Rules.sequence(a)
					if not sequence or sequence <= pt.sequence then return end
					pt.sequence = sequence
					why = dodge(seat, now)
				end
				if why and sequence then context.send({player}, Rules.REJECT, sequence, why) end
			end,
			finish = function()
				if finished then return end
				local now = context.clock()
				ending = true -- settling now must not end the round a second time
				settle(now)
				finished = true
				local completed = now >= schedule.endsAt - 0.05
				local results: {Rules.RoomResult} = {}
				for _, room in rooms do
					table.clear(room.projectiles)
					local stats: {Rules.Stats} = {}
					local humans = false
					for _, seat in room.seats do
						local h = seat.holder
						seat.chargeStartedAt = nil
						if not h.bot then humans = true end
						table.insert(stats, { participant = h.id, score = h.score, kos = h.kos, hits = h.hits, deaths = h.deaths, draw = h.draw })
					end
					local forfeits: {number} = {}
					for _, pt in participants do
						if pt.room == room.index and pt.forfeited then table.insert(forfeits, pt.id) end
					end
					local ranked = Rules.rank(stats)
					local done = completed and humans
					local placements: {Rules.Placement} = {}
					for place, s in ranked do
						table.insert(placements, { participant = s.participant, place = place, score = s.score, hits = s.hits, kos = s.kos,
							deaths = s.deaths, starlights = if done and place == 1 then C.WINNER_STARLIGHTS else 0 })
					end
					local winner = if done and ranked[1] then participants[ranked[1].participant] else nil
					-- One reward per room, to its winner if a human still here; bots get none.
					if winner and not winner.bot and winner.connected and winner.player then
						context.award(winner.player, C.WINNER_STARLIGHTS)
					end
					local result: Rules.RoomResult = { room = room.index, status = if done then "completed" else "aborted",
						winner = if winner then winner.id else nil, tieBreak = if done then Rules.tieBreak(ranked) else nil,
						placements = placements, forfeits = forfeits }
					table.insert(results, result)
				end
				-- Everyone gets their own room in full and the other rooms' winners.
				local function resultsFor(room: number): types.Value
					local out: {Rules.RoomResult} = {}
					for _, r in results do
						if r.room == room then
							table.insert(out, 1, r)
						else
							local trimmed = table.clone(r)
							trimmed.placements = if r.status == "completed" then { r.placements[1] } else {}
							trimmed.forfeits = {}
							table.insert(out, trimmed)
						end
					end
					return Rules.resultsValue(out)
				end
				for _, pt in participants do
					if not pt.bot and pt.connected and not pt.forfeited and pt.player then
						context.send({pt.player}, Rules.RESULTS, resultsFor(pt.room))
					end
				end
				for _, player in spectators do context.send({player}, Rules.RESULTS, resultsFor(1)) end
			end,
			inspect = function(player: types.Player): (number?, {Rules.Actor})
				local pt = byAccount[player.player_id]
				if not pt or pt.forfeited then return nil, {} end
				local actors: {Rules.Actor} = {}
				for _, seat in rooms[pt.room].seats do table.insert(actors, actorOf(seat)) end
				return pt.room, actors
			end,
		}
	end,
}
