--!strict
-- Blast Mining's tuning, schedule, scoring and wire format, the same on the
-- server and every client. The server is the authority: it draws each
-- participant's stream of falling items, judges every swing and keeps the
-- scores; clients only render from the times it sends.
--
-- Each participant has a *stream* (a number fixed for the round) of rocks,
-- gems and bombs that fall into their strike area. A swing hits the unhit item
-- of its own stream whose strike time is nearest, if within HIT_WINDOW of it;
-- otherwise it misses, harmlessly. Items nobody hits pass without effect.
--
-- Messages (the cycle's GAME channel; see server/Minigame and client/Minigame).
-- Times are the server's clock, in seconds:
--   client -> server: SYNC, clientTime  |  SWING, sequence, at
--   server -> client: SYNC, clientTime, serverTime  (clock sync)
--                     SNAPSHOT, snapshot  (the round: on arrival and when it starts)
--                     SPAWN, items  (shortly before each item appears)
--                     SWING, stream, sequence, at, slowed, itemId  (an accepted swing; 0: a miss)
--                     REJECT, sequence  (to its sender: a swing that did not count)
--                     HIT, hit  |  RESULTS, standings
-- `at` in a client's SWING is its estimate of the server time of the tap; the
-- server takes it only within MAX_COMPENSATION before it arrived.
local types = require("@moonbase/types")
local value = require("@moonbase/value")
local Standings = require("../../shared/Standings")

local Rules = {}

Rules.SYNC = "sync"
Rules.SWING = "swing"
Rules.SNAPSHOT = "snapshot"
Rules.SPAWN = "spawn"
Rules.REJECT = "reject"
Rules.HIT = "hit"
Rules.RESULTS = "results"

-- Tuning (seconds unless noted). The server applies these; clients mirror them
-- only to predict and draw.
Rules.CONFIG = table.freeze({
	DURATION = 60,
	PREPARATION = 3, -- the countdown before play (the cycle's intro adds a moment for loading)
	SPACING = 0.65, -- between items' base strike times
	JITTER = 0.41, -- added to each strike time, 0..JITTER
	FIRST = 0.78, -- the first item's base strike time after the start
	FALL_MIN = 0.43, FALL_MAX = 0.76, -- visible fall
	SPEED_UP = 0.2, -- falls end the round this much shorter
	DRIFT = 18, -- logical pixels of sideways drift, at most, either way
	HIT_WINDOW = 0.105, -- either side of the strike time
	COOLDOWN = 0.19, SLOW_COOLDOWN = 0.41,
	SLOW = 0.9, -- a bomb slows swings this long after the hit
	SHAKE = 0.34,
	SWING = 0.25, SLOW_SWING = 0.42, -- the swing animation
	ROCK = 0.6, GEM = 0.08, BOMB = 0.32, -- item odds
	-- How far ahead of an item's appearance the server discloses it, and how
	-- long before arrival a claimed tap time may be.
	LEAD = 0.35, MAX_COMPENSATION = 0.15,
	-- Slack in the cooldown check for timing noise between taps.
	COOLDOWN_SLACK = 0.02,
	-- The last strike leaves this long before the end, so eligible swings are
	-- in before play stops.
	TAIL = 0.3,
	-- The hand, as a fraction of the avatar's height: right of centre, and up
	-- from the feet. Used when the avatar renderer gives no hand anchor.
	HAND_X = 0.16, HAND_Y = 0.49,
})
local C = Rules.CONFIG

Rules.VALUES = table.freeze({ rock = 1, gem = 3, bomb = -3 } :: {[string]: number})
Rules.PLACES = Standings.PLACES
-- Starlights for 1st, 2nd and 3rd.
Rules.AWARDS = Standings.PRIZES
Rules.MAX_PLAYERS = 64
Rules.MAX_NAME = 64

export type Kind = "rock" | "gem" | "bomb"
export type Item = { id: number, stream: number, kind: Kind, spawnAt: number, strikeAt: number, drift: number }
export type Miner = { player: number, session: number, stream: number, name: string, outfit: {number}?,
	score: number, slowUntil: number, connected: boolean }
export type Snapshot = { startsAt: number, endsAt: number, serverNow: number, miners: {Miner}, items: {Item},
	hit: {number}, lastSequence: number, over: boolean }
export type Hit = { event: number, stream: number, item: number, kind: Kind, delta: number, total: number,
	at: number, slowUntil: number }
export type Standing = { player: number, name: string, score: number, place: number, starlights: number }

-- The fall duration of an item striking [elapsed] into the round, for a 0..1 draw.
function Rules.fall(elapsed: number, draw: number): number
	local progress = math.clamp(elapsed / C.DURATION, 0, 1)
	return (C.FALL_MIN + draw * (C.FALL_MAX - C.FALL_MIN)) * (1 - C.SPEED_UP * progress)
end

function Rules.kind(draw: number): Kind
	if draw < C.BOMB then return "bomb" end
	if draw < C.BOMB + C.GEM then return "gem" end
	return "rock"
end

-- One stream's items for a round starting at [startsAt]; [random]() returns
-- 0..1, drawn independently for each item's kind, jitter, fall and drift.
-- Ids are [base] + index, unique across the round's streams.
function Rules.schedule(stream: number, startsAt: number, base: number, random: () -> number): {Item}
	local items: {Item} = {}
	local i = 0
	while true do
		local kind, jitter, fall, drift = random(), random(), random(), random()
		local elapsed = C.FIRST + i * C.SPACING + jitter * C.JITTER
		if elapsed > C.DURATION - C.TAIL then break end
		local strikeAt = startsAt + elapsed
		table.insert(items, { id = base + i, stream = stream, kind = Rules.kind(kind),
			strikeAt = strikeAt, spawnAt = strikeAt - Rules.fall(elapsed, fall), drift = (drift * 2 - 1) * C.DRIFT })
		i += 1
	end
	return items
end

function Rules.cooldown(at: number, slowUntil: number): number
	return if at < slowUntil then C.SLOW_COOLDOWN else C.COOLDOWN
end

-- The unhit item of [items] a swing at [at] strikes: the nearest within the
-- window; nil for a miss.
function Rules.target(items: {Item}, hit: {[number]: boolean}, at: number): Item?
	local best: Item? = nil
	local gap = C.HIT_WINDOW + 1e-9
	for _, item in items do
		local away = math.abs(item.strikeAt - at)
		if away <= gap and not hit[item.id] then best, gap = item, away end
	end
	return best
end

export type Score = Standings.Score

-- Points first, then who reached their final score first, then player id.
Rules.rank = Standings.rank

-- Wire format.

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

local function name(v: unknown): string?
	return if type(v) == "string" and #v > 0 and #v <= Rules.MAX_NAME then v else nil
end

local function kindOf(v: unknown): Kind?
	return if v == "rock" or v == "gem" or v == "bomb" then v :: Kind else nil
end

local function numbers(ids: {number}): {types.Value}
	local out: {types.Value} = {}
	for i, n in ids do out[i] = n end
	return value.array(out)
end

-- Server times go out rounded to the millisecond.
local function ms(t: number): number return math.round(t * 1000) / 1000 end

function Rules.itemValue(item: Item): types.Value
	return { id = item.id, stream = item.stream, kind = item.kind, spawnAt = ms(item.spawnAt), strikeAt = ms(item.strikeAt),
		drift = math.round(item.drift * 10) / 10 }
end

function Rules.item(v: unknown): Item?
	local r = record(v)
	if not r then return nil end
	local id, stream, kind = integer(r.id, 0, MAX_ID), integer(r.stream, 1, Rules.MAX_PLAYERS), kindOf(r.kind)
	local spawnAt, strikeAt, drift = real(r.spawnAt, 0, 1e9), real(r.strikeAt, 0, 1e9), real(r.drift, -100, 100)
	if not id or not stream or not kind or not spawnAt or not strikeAt or not drift or spawnAt > strikeAt then return nil end
	return { id = id, stream = stream, kind = kind, spawnAt = spawnAt, strikeAt = strikeAt, drift = drift }
end

function Rules.itemsValue(items: {Item}): types.Value
	local out: {types.Value} = {}
	for i, item in items do out[i] = Rules.itemValue(item) end
	return value.array(out)
end

function Rules.items(v: unknown): {Item}?
	return list(v, 4096, Rules.item)
end

function Rules.snapshotValue(s: Snapshot): types.Value
	local miners: {types.Value} = {}
	for i, m in s.miners do
		local out: {[string]: types.Value} = { player = m.player, session = m.session, stream = m.stream, name = m.name,
			score = m.score, slowUntil = ms(m.slowUntil), connected = m.connected }
		if m.outfit then out.outfit = numbers(m.outfit) end
		miners[i] = out
	end
	return { startsAt = ms(s.startsAt), endsAt = ms(s.endsAt), serverNow = ms(s.serverNow), miners = value.array(miners),
		items = Rules.itemsValue(s.items), hit = numbers(s.hit), lastSequence = s.lastSequence, over = s.over }
end

function Rules.snapshot(v: unknown): Snapshot?
	local r = record(v)
	if not r then return nil end
	local miners = list(r.miners, Rules.MAX_PLAYERS, function(item: unknown): Miner?
		local m = record(item)
		if not m then return nil end
		local player, session, stream = integer(m.player, 0, MAX_ID), integer(m.session, 1, MAX_ID), integer(m.stream, 1, Rules.MAX_PLAYERS)
		local shown, score, slowUntil = name(m.name), integer(m.score, 0, MAX_ID), real(m.slowUntil, 0, 1e9)
		local outfit = if m.outfit == nil then nil else list(m.outfit, 200, function(id: unknown): number? return integer(id, -2^31, 2^31) end)
		if not player or not session or not stream or not shown or not score or not slowUntil or type(m.connected) ~= "boolean"
			or (m.outfit ~= nil and not outfit) then return nil end
		return { player = player, session = session, stream = stream, name = shown, outfit = outfit, score = score,
			slowUntil = slowUntil, connected = m.connected :: boolean }
	end)
	local items = Rules.items(r.items)
	local hit = list(r.hit, 4096, function(id: unknown): number? return integer(id, 0, MAX_ID) end)
	local startsAt, endsAt, now = real(r.startsAt, 0, 1e9), real(r.endsAt, 0, 1e9), real(r.serverNow, 0, 1e9)
	local last = integer(r.lastSequence, 0, MAX_ID)
	if not miners or not items or not hit or not startsAt or not endsAt or not now or not last or type(r.over) ~= "boolean" then return nil end
	return { startsAt = startsAt, endsAt = endsAt, serverNow = now, miners = miners, items = items, hit = hit,
		lastSequence = last, over = r.over :: boolean }
end

function Rules.hitValue(h: Hit): types.Value
	return { event = h.event, stream = h.stream, item = h.item, kind = h.kind, delta = h.delta, total = h.total,
		at = ms(h.at), slowUntil = ms(h.slowUntil) }
end

function Rules.hit(v: unknown): Hit?
	local r = record(v)
	if not r then return nil end
	local event, stream, item, kind = integer(r.event, 1, MAX_ID), integer(r.stream, 1, Rules.MAX_PLAYERS), integer(r.item, 0, MAX_ID), kindOf(r.kind)
	local delta, total = integer(r.delta, -3, 3), integer(r.total, 0, MAX_ID)
	local at, slowUntil = real(r.at, 0, 1e9), real(r.slowUntil, 0, 1e9)
	if not event or not stream or not item or not kind or not delta or not total or not at or not slowUntil then return nil end
	return { event = event, stream = stream, item = item, kind = kind, delta = delta, total = total, at = at, slowUntil = slowUntil }
end

function Rules.standingsValue(standings: {Standing}): types.Value
	local out: {types.Value} = {}
	for i, s in standings do
		out[i] = { player = s.player, name = s.name, score = s.score, place = s.place, starlights = s.starlights }
	end
	return value.array(out)
end

function Rules.standings(v: unknown): {Standing}?
	return list(v, Rules.MAX_PLAYERS, function(item: unknown): Standing?
		local r = record(item)
		if not r then return nil end
		local player, shown, score = integer(r.player, 0, MAX_ID), name(r.name), integer(r.score, 0, MAX_ID)
		local place, starlights = integer(r.place, 1, Rules.MAX_PLAYERS), integer(r.starlights, 0, 1000)
		if not player or not shown or not score or not place or not starlights then return nil end
		return { player = player, name = shown, score = score, place = place, starlights = starlights }
	end)
end

-- A swing: (sequence, claimed server time or nil).
function Rules.swing(sequence: unknown, at: unknown): (number?, number?)
	return integer(sequence, 1, MAX_ID), real(at, 0, 1e9)
end

Rules.ms = ms
return table.freeze(Rules)
