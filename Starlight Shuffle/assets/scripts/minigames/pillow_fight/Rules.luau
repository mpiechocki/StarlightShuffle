--!strict
-- Pillow Fight's tuning, rules and wire format, the same on the server and
-- every client. A short free-for-all in small rooms of three or four: each
-- player aims at a rival, holds and releases a pillow throw, and times a
-- dodge against pillows coming at them. Three hearts; knocked out, back in a
-- few seconds. Every room has exactly one winner (see `compare`).
--
-- Grouping: H humans in the frozen roster make one room of max(3, H) when
-- H <= 4, else ceil(H / 4) rooms of four with the humans shuffled and dealt
-- round-robin (rooms differ by at most one human); only then do labelled
-- filler bots take the empty slots. Rooms never start with two players or
-- only bots.
--
-- Everyone is a participant with a server-made id (humans and bots alike);
-- a room's seats are fixed for the round and an actor's live state belongs to
-- its seat, so a bot replacing a departed human keeps the seat, hearts and
-- cooldowns but starts its own score. Times are the server's clock, in seconds.
--
-- Messages (the cycle's GAME channel):
--   client -> server: SYNC, clientTime
--                     CHARGE, sequence, "begin" | "cancel"
--                     THROW, sequence, targetParticipant
--                     DODGE, sequence
--   server -> client: SYNC, clientTime, serverTime
--                     SNAPSHOT, snapshot (to each player: on arrival and roster changes)
--                     EVENT, event (to a room's players: what changed, in order)
--                     REJECT, sequence, reason (to its sender: an intent that did nothing)
--                     RESULTS, results (to each player: their room in full, other rooms' winners)
local types = require("@moonbase/types")
local value = require("@moonbase/value")
local Rewards = require("../../shared/Rewards")

local Rules = {}

Rules.VERSION = 1 -- of CONFIG; raise it when tuning changes
Rules.SYNC = "sync"
Rules.CHARGE = "charge"
Rules.THROW = "throw"
Rules.DODGE = "dodge"
Rules.SNAPSHOT = "snapshot"
Rules.EVENT = "event"
Rules.REJECT = "reject"
Rules.RESULTS = "results"

Rules.CONFIG = table.freeze({
	INSTRUCTIONS = 15, LESSON = 5, -- the cycle's announcement: three five-second examples
	REVEAL = 4, -- the group reveal, only with more than one room
	COUNTDOWN = 3,
	PLAY = 120,
	HEARTS = 3,
	MIN_CHARGE = 0.18, FULL_CHARGE = 0.9, MAX_CHARGE = 3.5,
	THROW_COOLDOWN = 1, FLIGHT = 1,
	DODGE_WINDOW = 0.48, DODGE_COOLDOWN = 2.6,
	DANGER = 0.42, -- the red ! and the lit Dodge, before a pillow lands on you
	WARNING = 0.65, -- the warning ring, before a pillow lands on you
	STUN = 0.3, RESPAWN = 3, SPAWN_PROTECTION = 1.2,
	HIT_SCORE = 1, KO_SCORE = 3,
	ROOM = 4, MIN_ROOM = 3,
	RECONNECT = 8, -- seconds a disconnected human keeps their seat before a bot takes it
	WINNER_STARLIGHTS = Rewards.PLACES[1], -- every room winner's reward (the cycle's first prize)
	RATE = 30, -- intents a participant may send per second
	-- Filler bots: approachable and fallible, on the same rules as everyone.
	BOT = table.freeze({
		THINK = 0.18, THINK_JITTER = 0.12, -- seconds between decisions
		START = 0.12, -- chance per decision to start charging when ready
		HOLD = 0.5, HOLD_SPREAD = 0.6, -- seconds held before releasing (a third reach a full charge)
		DODGE = 0.3, -- chance to try dodging a pillow coming at them
		DODGE_LEAD = 0.05, DODGE_LEAD_SPREAD = 0.55, -- dodges this long before impact (late ones miss)
	}),
	-- Presentation.
	HIT_SHAKE = 0.32, HURT_FLASH = 0.4, FEATHERS = 1, ARC = 65,
})
local C = Rules.CONFIG

Rules.MAX_PARTICIPANTS = 128
Rules.MAX_ROOMS = 32
Rules.MAX_NAME = 64
Rules.BOT_NAMES = table.freeze({ "Pip", "Mallow", "Bunny", "Cloud", "Peep", "Dew" })
Rules.DOLLS = 3 -- bot avatar artworks

-- Room sizes for [humans] eligible humans: none for none.
function Rules.groupPlan(humans: number): {number}
	if humans < 1 then return {} end
	if humans <= C.ROOM then return { math.max(C.MIN_ROOM, humans) } end
	local plan: {number} = {}
	for i = 1, math.ceil(humans / C.ROOM) do plan[i] = C.ROOM end
	return plan
end

-- An unbiased in-place shuffle with [random] (0 <= random() < 1).
function Rules.shuffle<T>(list: {T}, random: () -> number)
	for i = #list, 2, -1 do
		local j = math.min(i, math.floor(random() * i) + 1)
		list[i], list[j] = list[j], list[i]
	end
end

-- The rooms' humans for [humans] (any order): shuffled, then dealt
-- round-robin. Each room's size is groupPlan's; the rest of it is bots.
function Rules.assign(humans: {number}, random: () -> number): {{number}}
	local plan = Rules.groupPlan(#humans)
	local order = table.clone(humans)
	Rules.shuffle(order, random)
	local rooms: {{number}} = {}
	for i = 1, #plan do rooms[i] = {} end
	for i, id in order do table.insert(rooms[(i - 1) % #plan + 1], id) end
	return rooms
end

export type Schedule = { startsAt: number, playAt: number, endsAt: number, rooms: number }
export type Phase = "instructions" | "reveal" | "countdown" | "playing" | "over"

-- The round's times once the cycle's announcement ends at [startsAt].
function Rules.schedule(startsAt: number, rooms: number): Schedule
	local playAt = startsAt + (if rooms > 1 then C.REVEAL else 0) + C.COUNTDOWN
	return { startsAt = startsAt, playAt = playAt, endsAt = playAt + C.PLAY, rooms = rooms }
end

function Rules.phaseAt(s: Schedule, now: number): Phase
	if now < s.startsAt then return "instructions" end
	if now < s.playAt - C.COUNTDOWN then return "reveal" end
	if now < s.playAt then return "countdown" end
	if now < s.endsAt then return "playing" end
	return "over"
end

-- The longest a round can take after the announcement (the cycle's duration).
Rules.LONGEST = C.REVEAL + C.COUNTDOWN + C.PLAY

export type Stats = { participant: number, score: number, kos: number, hits: number, deaths: number, draw: number }
export type TieBreak = "score" | "knockouts" | "hits" | "deaths" | "drawOrder"

-- The one order of a room: higher score, more knockouts, more hits, fewer
-- knockouts suffered, then the server's draw ticket (then id, for corrupt data).
function Rules.compare(a: Stats, b: Stats): boolean
	if a.score ~= b.score then return a.score > b.score end
	if a.kos ~= b.kos then return a.kos > b.kos end
	if a.hits ~= b.hits then return a.hits > b.hits end
	if a.deaths ~= b.deaths then return a.deaths < b.deaths end
	if a.draw ~= b.draw then return a.draw < b.draw end
	return a.participant < b.participant
end

function Rules.rank(list: {Stats}): {Stats}
	local out = table.clone(list)
	table.sort(out, Rules.compare)
	return out
end

-- What separated the first two of [ranked].
function Rules.tieBreak(ranked: {Stats}): TieBreak
	local a, b = ranked[1], ranked[2]
	if not a or not b or a.score ~= b.score then return "score" end
	if a.kos ~= b.kos then return "knockouts" end
	if a.hits ~= b.hits then return "hits" end
	if a.deaths ~= b.deaths then return "deaths" end
	return "drawOrder"
end

-- Wire format.

export type Participant = { id: number, name: string, bot: boolean, outfit: {number}?, doll: number?,
	room: number, seat: number, draw: number, forfeited: boolean }
-- A seat's live state, with its current holder's stats.
export type Actor = { seat: number, participant: number, hp: number, score: number, hits: number, kos: number, deaths: number,
	charging: boolean, throwReadyAt: number, dodgeAt: number, dodgeUntil: number, dodgeReadyAt: number, stunnedUntil: number,
	respawnAt: number, protectedUntil: number }
export type Projectile = { id: number, from: number, to: number, startedAt: number, impactAt: number, power: number }
export type EventKind = "charge" | "cancel" | "throw" | "dodge" | "hit" | "ko" | "miss" | "blocked" | "fizzle" | "respawn"
export type Event = { event: number, room: number, kind: EventKind, at: number, actors: {Actor}, projectile: Projectile? }
export type Snapshot = { version: number, startsAt: number, playAt: number, endsAt: number, rooms: number, serverNow: number,
	participants: {Participant}, me: number?, room: number, actors: {Actor}, projectiles: {Projectile}, lastEvent: number,
	lastSequence: number }
export type Placement = { participant: number, place: number, score: number, hits: number, kos: number, deaths: number,
	starlights: number }
export type RoomResult = { room: number, status: "completed" | "aborted", winner: number?, tieBreak: TieBreak?,
	placements: {Placement}, forfeits: {number} }

-- Is [actor] standing in the fight (not knocked out)?
function Rules.active(actor: Actor): boolean
	return actor.respawnAt == 0
end

-- Would [projectile] land on [actor] unprotected and undodged, as known now?
function Rules.threatens(projectile: Projectile, actor: Actor): boolean
	if not Rules.active(actor) then return false end
	if actor.protectedUntil >= projectile.impactAt then return false end
	if actor.dodgeAt <= projectile.impactAt and projectile.impactAt <= actor.dodgeUntil then return false end
	return true
end

-- The soonest pillow coming at [actor] within [window] seconds of [now], if any.
function Rules.incoming(projectiles: {Projectile}, actor: Actor, now: number, window: number): Projectile?
	local soonest: Projectile? = nil
	for _, s in projectiles do
		local left = s.impactAt - now
		if s.to == actor.participant and left > 0 and left <= window and Rules.threatens(s, actor)
			and (not soonest or s.impactAt < soonest.impactAt) then soonest = s end
	end
	return soonest
end

local MAX_ID = 9007199254740991

local function integer(v: unknown, low: number, high: number): number?
	if type(v) ~= "number" or v ~= math.floor(v) or v < low or v > high then return nil end
	return v
end

local function real(v: unknown, low: number, high: number): number?
	if type(v) ~= "number" or v ~= v or v < low or v > high then return nil end
	return v
end

local function record(v: unknown): {[unknown]: unknown}?
	return if type(v) == "table" then v :: {[unknown]: unknown} else nil
end

local function list<T>(v: unknown, limit: number, read: (unknown) -> T?): {T}?
	local items = record(v)
	if not items or #items > limit then return nil end
	local out: {T} = {}
	local seen = 0
	for key, item in items do
		local index, parsed = integer(key, 1, #items), read(item)
		if not index or parsed == nil then return nil end
		out[index] = parsed
		seen += 1
	end
	return if seen == #items then out else nil
end

local function arrayOf<T>(items: {T}, write: (T) -> types.Value): types.Value
	local out: {types.Value} = {}
	for i, item in items do out[i] = write(item) end
	return value.array(out)
end

local function name(v: unknown): string?
	return if type(v) == "string" and #v > 0 and #v <= Rules.MAX_NAME then v else nil
end

local function ms(t: number): number return math.round(t * 1000) / 1000 end
Rules.ms = ms

local function participantValue(pt: Participant): types.Value
	local out: {[string]: types.Value} = { id = pt.id, name = pt.name, bot = pt.bot, room = pt.room, seat = pt.seat, draw = pt.draw,
		forfeited = pt.forfeited }
	if pt.outfit then out.outfit = arrayOf(pt.outfit, function(n: number): types.Value return n end) end
	if pt.doll then out.doll = pt.doll end
	return out
end

local function participant(v: unknown): Participant?
	local r = record(v)
	if not r then return nil end
	local id, shown, room = integer(r.id, 1, MAX_ID), name(r.name), integer(r.room, 1, Rules.MAX_ROOMS)
	local seat, draw = integer(r.seat, 1, C.ROOM), integer(r.draw, 1, Rules.MAX_PARTICIPANTS)
	local outfit = if r.outfit == nil then nil else list(r.outfit, 200, function(n: unknown): number? return integer(n, -2^31, 2^31) end)
	local doll = if r.doll == nil then nil else integer(r.doll, 1, Rules.DOLLS)
	if not id or not shown or not room or not seat or not draw or type(r.bot) ~= "boolean" or type(r.forfeited) ~= "boolean"
		or (r.outfit ~= nil and not outfit) or (r.doll ~= nil and not doll) then return nil end
	return { id = id, name = shown, bot = r.bot :: boolean, outfit = outfit, doll = doll, room = room, seat = seat, draw = draw,
		forfeited = r.forfeited :: boolean }
end

local function actorValue(a: Actor): types.Value
	return { seat = a.seat, participant = a.participant, hp = a.hp, score = a.score, hits = a.hits, kos = a.kos, deaths = a.deaths,
		charging = a.charging, throwReadyAt = ms(a.throwReadyAt), dodgeAt = ms(a.dodgeAt), dodgeUntil = ms(a.dodgeUntil),
		dodgeReadyAt = ms(a.dodgeReadyAt), stunnedUntil = ms(a.stunnedUntil), respawnAt = ms(a.respawnAt),
		protectedUntil = ms(a.protectedUntil) }
end

local function actor(v: unknown): Actor?
	local r = record(v)
	if not r then return nil end
	local seat, id, hp = integer(r.seat, 1, C.ROOM), integer(r.participant, 1, MAX_ID), integer(r.hp, 0, C.HEARTS)
	local score, hits, kos, deaths = integer(r.score, 0, MAX_ID), integer(r.hits, 0, MAX_ID), integer(r.kos, 0, MAX_ID), integer(r.deaths, 0, MAX_ID)
	local t: {number} = {}
	for i, key in { "throwReadyAt", "dodgeAt", "dodgeUntil", "dodgeReadyAt", "stunnedUntil", "respawnAt", "protectedUntil" } do
		local at = real(r[key], 0, 1e9)
		if not at then return nil end
		t[i] = at
	end
	if not seat or not id or not hp or not score or not hits or not kos or not deaths or type(r.charging) ~= "boolean" then return nil end
	return { seat = seat, participant = id, hp = hp, score = score, hits = hits, kos = kos, deaths = deaths, charging = r.charging :: boolean,
		throwReadyAt = t[1], dodgeAt = t[2], dodgeUntil = t[3], dodgeReadyAt = t[4], stunnedUntil = t[5], respawnAt = t[6],
		protectedUntil = t[7] }
end

local function projectileValue(s: Projectile): types.Value
	return { id = s.id, from = s.from, to = s.to, startedAt = ms(s.startedAt), impactAt = ms(s.impactAt), power = s.power }
end

local function projectile(v: unknown): Projectile?
	local r = record(v)
	if not r then return nil end
	local id, from, to = integer(r.id, 1, MAX_ID), integer(r.from, 1, MAX_ID), integer(r.to, 1, MAX_ID)
	local startedAt, impactAt, power = real(r.startedAt, 0, 1e9), real(r.impactAt, 0, 1e9), integer(r.power, 1, 2)
	if not id or not from or not to or not startedAt or not impactAt or not power then return nil end
	return { id = id, from = from, to = to, startedAt = startedAt, impactAt = impactAt, power = power }
end

local MAX_PROJECTILES = 64
local KINDS: {[string]: boolean} = { charge = true, cancel = true, throw = true, dodge = true, hit = true, ko = true, miss = true,
	blocked = true, fizzle = true, respawn = true }

function Rules.eventValue(e: Event): types.Value
	local out: {[string]: types.Value} = { event = e.event, room = e.room, kind = e.kind, at = ms(e.at), actors = arrayOf(e.actors, actorValue) }
	if e.projectile then out.projectile = projectileValue(e.projectile) end
	return out
end

function Rules.event(v: unknown): Event?
	local r = record(v)
	if not r then return nil end
	local event, room, at = integer(r.event, 1, MAX_ID), integer(r.room, 1, Rules.MAX_ROOMS), real(r.at, 0, 1e9)
	local actors = list(r.actors, C.ROOM, actor)
	local shot = if r.projectile == nil then nil else projectile(r.projectile)
	if not event or not room or not at or not actors or type(r.kind) ~= "string" or not KINDS[r.kind :: string]
		or (r.projectile ~= nil and not shot) then return nil end
	return { event = event, room = room, kind = r.kind :: EventKind, at = at, actors = actors, projectile = shot }
end

function Rules.snapshotValue(s: Snapshot): types.Value
	local out: {[string]: types.Value} = { version = s.version, startsAt = ms(s.startsAt), playAt = ms(s.playAt), endsAt = ms(s.endsAt),
		rooms = s.rooms, serverNow = ms(s.serverNow), participants = arrayOf(s.participants, participantValue), room = s.room,
		actors = arrayOf(s.actors, actorValue), projectiles = arrayOf(s.projectiles, projectileValue), lastEvent = s.lastEvent,
		lastSequence = s.lastSequence }
	if s.me then out.me = s.me end
	return out
end

function Rules.snapshot(v: unknown): Snapshot?
	local r = record(v)
	if not r then return nil end
	local version, rooms, room = integer(r.version, 1, 1000), integer(r.rooms, 1, Rules.MAX_ROOMS), integer(r.room, 1, Rules.MAX_ROOMS)
	local startsAt, playAt, endsAt, now = real(r.startsAt, 0, 1e9), real(r.playAt, 0, 1e9), real(r.endsAt, 0, 1e9), real(r.serverNow, 0, 1e9)
	local participants = list(r.participants, Rules.MAX_PARTICIPANTS, participant)
	local actors, projectiles = list(r.actors, C.ROOM, actor), list(r.projectiles, MAX_PROJECTILES, projectile)
	local me = if r.me == nil then nil else integer(r.me, 1, MAX_ID)
	local lastEvent, lastSequence = integer(r.lastEvent, 0, MAX_ID), integer(r.lastSequence, 0, MAX_ID)
	if not version or not rooms or not room or not startsAt or not playAt or not endsAt or not now or not participants or not actors
		or not projectiles or not lastEvent or not lastSequence or (r.me ~= nil and not me) then return nil end
	return { version = version, startsAt = startsAt, playAt = playAt, endsAt = endsAt, rooms = rooms, serverNow = now,
		participants = participants, me = me, room = room, actors = actors, projectiles = projectiles, lastEvent = lastEvent,
		lastSequence = lastSequence }
end

local function placementValue(p: Placement): types.Value
	return { participant = p.participant, place = p.place, score = p.score, hits = p.hits, kos = p.kos, deaths = p.deaths,
		starlights = p.starlights }
end

local function placement(v: unknown): Placement?
	local r = record(v)
	if not r then return nil end
	local id, place = integer(r.participant, 1, MAX_ID), integer(r.place, 1, C.ROOM)
	local score, hits, kos, deaths = integer(r.score, 0, MAX_ID), integer(r.hits, 0, MAX_ID), integer(r.kos, 0, MAX_ID), integer(r.deaths, 0, MAX_ID)
	local starlights = integer(r.starlights, 0, 1000)
	if not id or not place or not score or not hits or not kos or not deaths or not starlights then return nil end
	return { participant = id, place = place, score = score, hits = hits, kos = kos, deaths = deaths, starlights = starlights }
end

local TIE_BREAKS: {[string]: boolean} = { score = true, knockouts = true, hits = true, deaths = true, drawOrder = true }

function Rules.resultsValue(rooms: {RoomResult}): types.Value
	return arrayOf(rooms, function(room: RoomResult): types.Value
		local out: {[string]: types.Value} = { room = room.room, status = room.status, placements = arrayOf(room.placements, placementValue),
			forfeits = arrayOf(room.forfeits, function(n: number): types.Value return n end) }
		if room.winner then out.winner = room.winner end
		if room.tieBreak then out.tieBreak = room.tieBreak end
		return out
	end)
end

function Rules.results(v: unknown): {RoomResult}?
	return list(v, Rules.MAX_ROOMS, function(item: unknown): RoomResult?
		local r = record(item)
		if not r then return nil end
		local room = integer(r.room, 1, Rules.MAX_ROOMS)
		local placements = list(r.placements, C.ROOM, placement)
		local forfeits = list(r.forfeits, Rules.MAX_PARTICIPANTS, function(n: unknown): number? return integer(n, 1, MAX_ID) end)
		local winner = if r.winner == nil then nil else integer(r.winner, 1, MAX_ID)
		local status = r.status
		local tie = r.tieBreak
		if not room or not placements or not forfeits or (status ~= "completed" and status ~= "aborted") or (r.winner ~= nil and not winner)
			or (tie ~= nil and (type(tie) ~= "string" or not TIE_BREAKS[tie :: string])) then return nil end
		-- A completed room names its one winner, who is its only first place.
		if status == "completed" then
			if not winner or not placements[1] or placements[1].participant ~= winner then return nil end
		elseif winner then return nil end
		return { room = room, status = status :: any, winner = winner, tieBreak = tie :: TieBreak?, placements = placements,
			forfeits = forfeits }
	end)
end

-- Intents: (sequence, op) / (sequence, target) / (sequence), or nils.
function Rules.chargeIntent(a: unknown, b: unknown): (number?, string?)
	local sequence = integer(a, 1, MAX_ID)
	if not sequence or (b ~= "begin" and b ~= "cancel") then return nil, nil end
	return sequence, b :: string
end

function Rules.throwIntent(a: unknown, b: unknown): (number?, number?)
	local sequence, target = integer(a, 1, MAX_ID), integer(b, 1, MAX_ID)
	if not sequence or not target then return nil, nil end
	return sequence, target
end

function Rules.sequence(a: unknown): number?
	return integer(a, 1, MAX_ID)
end

return table.freeze(Rules)
