--!strict
-- Lucky Shot's tuning, cloud field, scoring and wire format, the same on the
-- server and every client. Unlike Blast Mining's separate streams, everyone
-- shoots at one shared, server-owned field of clouds: the first valid claim
-- takes a cloud for everyone.
--
-- Positions are on one canonical playfield, x and y from 0 to 1 across the
-- game surface (y down); each client maps it onto its own view. Clouds keep
-- inside the cloud zone (CLOUD_X, CLOUD_Y), clear of the HUD at the top, the
-- reload meter at the right and the crowd below. A cloud drifts sideways from
-- its spawn to its expiry and bobs slightly; its size is a fraction of the
-- playfield's width.
--
-- Messages (the cycle's GAME channel; times are the server's clock, in seconds):
--   client -> server: SYNC, clientTime  |  SHOOT, sequence, cloudId, at
--   server -> client: SYNC, clientTime, serverTime  (clock sync)
--                     SNAPSHOT, snapshot  (the round: on arrival)
--                     SPAWN, clouds  (as clouds appear)
--                     SHOT, shot  (an accepted shot: who, at which cloud, claimed or not)
--                     REJECT, sequence  (to its sender: a shot that did not count)
--                     RESULTS, standings
-- `at` in SHOOT is the client's estimate of the server time of the tap; the
-- server takes it only within MAX_COMPENSATION before it arrived.
local types = require("@moonbase/types")
local value = require("@moonbase/value")
local Standings = require("../../shared/Standings")

local Rules = {}

Rules.VERSION = 1 -- of CONFIG; raise it when tuning changes
Rules.SYNC = "sync"
Rules.SHOOT = "shoot"
Rules.SNAPSHOT = "snapshot"
Rules.SPAWN = "spawn"
Rules.SHOT = "shot"
Rules.REJECT = "reject"
Rules.RESULTS = "results"

Rules.CONFIG = table.freeze({
	DURATION = 45,
	PREPARATION = 10, -- the shared countdown (the cycle's intro)
	FINAL_COUNT = 3, -- its last seconds show a large 3, 2, 1
	RELOAD = 0.85,
	WHITE = 0.6, GOLD = 0.22, STORM = 0.18, -- cloud odds
	LIFE_MIN = 1.4, LIFE_MAX = 1.95, LIFE_CUT = 0.4, -- lifetime, and how much shorter by the end
	DRIFT_MIN = 0.07, DRIFT_MAX = 0.15, -- of the playfield width over a cloud's life
	BOB = 0.02, -- of the playfield height, at mid-life
	SIZE_MIN = 54 / 390, SIZE_MAX = 68 / 390, -- cloud width, of the playfield width
	WARNING = 0.33, -- the expiry warning before a cloud goes
	FIRST = 4, -- clouds at the start
	CLOUD_X = { 0.12, 0.74 }, CLOUD_Y = { 0.17, 0.5 }, -- where cloud centres may be
	SPREAD_X = 0.18, SPREAD_Y = 0.09, -- how far a new cloud keeps from the others
	TRIES = 45,
	LEAD = 0.12, -- seconds a cloud is announced before it shows
	MAX_COMPENSATION = 0.15,
	RELOAD_SLACK = 0.02,
	-- The hand, as a fraction of the avatar's height: right of centre, and up
	-- from the feet. Used when the avatar renderer gives no hand anchor.
	HAND_X = 0.17, HAND_Y = 0.5,
})
local C = Rules.CONFIG

Rules.VALUES = table.freeze({ white = 1, gold = 2, storm = -1 } :: {[string]: number})
Rules.PLACES = Standings.PLACES
Rules.AWARDS = Standings.PRIZES
Rules.MAX_PLAYERS = 64
Rules.MAX_NAME = 64

export type Kind = "white" | "gold" | "storm"
export type Cloud = { id: number, kind: Kind, x: number, y: number, drift: number, size: number,
	spawnAt: number, expiresAt: number }
export type Player = { player: number, session: number, seat: number, name: string, outfit: {number}?,
	score: number, reloadUntil: number, connected: boolean }
export type Snapshot = { version: number, startsAt: number, endsAt: number, serverNow: number, players: {Player},
	clouds: {Cloud}, lastSequence: number, lastEvent: number, over: boolean }
-- An accepted shot: `claimed` when it took the cloud (`delta` and `total` then
-- count), else `reason` says why not ("claimed": a rival was first; "expired").
export type Shot = { event: number, sequence: number, seat: number, cloud: number, claimed: boolean, reason: string,
	delta: number, total: number, at: number, reloadUntil: number }
export type Standing = { player: number, name: string, score: number, place: number, starlights: number }
export type Score = Standings.Score

-- How many clouds the field may hold at once, for [count] competitors.
function Rules.cap(count: number): number
	return math.min(10, 6 + math.ceil(math.max(0, count - 4) / 4))
end

-- Seconds until the next spawn, for [count] competitors and a 0..1 draw.
function Rules.interval(count: number, draw: number): number
	return math.max(0.2, (0.34 + draw * 0.19) / math.sqrt(math.max(1, count / 4)))
end

function Rules.kind(draw: number): Kind
	if draw < C.STORM then return "storm" end
	if draw < C.STORM + C.GOLD then return "gold" end
	return "white"
end

-- Where [cloud] is at server time [at]: (x, y) on the playfield, and how far
-- through its life (0..1).
function Rules.position(cloud: Cloud, at: number): (number, number, number)
	local f = math.clamp((at - cloud.spawnAt) / math.max(0.01, cloud.expiresAt - cloud.spawnAt), 0, 1)
	return cloud.x + cloud.drift * f, cloud.y - math.sin(f * math.pi) * C.BOB, f
end

-- A new cloud, starting at [at] with [elapsed] seconds of the round gone,
-- placed clear of [others] where it can be; nil when there is no room.
-- [random]() returns 0..1; kind, place, life, drift and size draw separately.
function Rules.cloud(id: number, at: number, elapsed: number, others: {Cloud}, random: () -> number): Cloud?
	local kind = Rules.kind(random())
	local progress = math.clamp(elapsed / C.DURATION, 0, 1)
	local life = C.LIFE_MIN + random() * (C.LIFE_MAX - C.LIFE_MIN) - progress * C.LIFE_CUT
	local drift = C.DRIFT_MIN + random() * (C.DRIFT_MAX - C.DRIFT_MIN)
	local size = C.SIZE_MIN + random() * (C.SIZE_MAX - C.SIZE_MIN)
	for _ = 1, C.TRIES do
		local x = C.CLOUD_X[1] + random() * (C.CLOUD_X[2] - C.CLOUD_X[1])
		local y = C.CLOUD_Y[1] + random() * (C.CLOUD_Y[2] - C.CLOUD_Y[1])
		-- Drift whichever way keeps the whole path in the cloud zone.
		local signed = if x + drift <= C.CLOUD_X[2] and (x - drift < C.CLOUD_X[1] or random() < 0.5) then drift else -drift
		local clear = true
		for _, other in others do
			local ox, oy = Rules.position(other, at)
			if math.abs(ox - x) < C.SPREAD_X and math.abs(oy - y) < C.SPREAD_Y then clear = false; break end
		end
		if clear then
			return { id = id, kind = kind, x = x, y = y, drift = signed, size = size, spawnAt = at, expiresAt = at + life }
		end
	end
	return nil
end

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
	return if v == "white" or v == "gold" or v == "storm" then v :: Kind else nil
end

local function numbers(ids: {number}): {types.Value}
	local out: {types.Value} = {}
	for i, n in ids do out[i] = n end
	return value.array(out)
end

-- Server times go out rounded to the millisecond; positions to 1/10000.
local function ms(t: number): number return math.round(t * 1000) / 1000 end
local function fine(n: number): number return math.round(n * 10000) / 10000 end
Rules.ms = ms

function Rules.cloudValue(c: Cloud): types.Value
	return { id = c.id, kind = c.kind, x = fine(c.x), y = fine(c.y), drift = fine(c.drift), size = fine(c.size),
		spawnAt = ms(c.spawnAt), expiresAt = ms(c.expiresAt) }
end

function Rules.cloudOf(v: unknown): Cloud?
	local r = record(v)
	if not r then return nil end
	local id, kind = integer(r.id, 1, MAX_ID), kindOf(r.kind)
	local x, y, drift, size = real(r.x, 0, 1), real(r.y, 0, 1), real(r.drift, -1, 1), real(r.size, 0.01, 0.5)
	local spawnAt, expiresAt = real(r.spawnAt, 0, 1e9), real(r.expiresAt, 0, 1e9)
	if not id or not kind or not x or not y or not drift or not size or not spawnAt or not expiresAt or expiresAt < spawnAt then return nil end
	return { id = id, kind = kind, x = x, y = y, drift = drift, size = size, spawnAt = spawnAt, expiresAt = expiresAt }
end

function Rules.cloudsValue(clouds: {Cloud}): types.Value
	local out: {types.Value} = {}
	for i, c in clouds do out[i] = Rules.cloudValue(c) end
	return value.array(out)
end

function Rules.clouds(v: unknown): {Cloud}?
	return list(v, 64, Rules.cloudOf)
end

function Rules.snapshotValue(s: Snapshot): types.Value
	local players: {types.Value} = {}
	for i, pl in s.players do
		local out: {[string]: types.Value} = { player = pl.player, session = pl.session, seat = pl.seat, name = pl.name,
			score = pl.score, reloadUntil = ms(pl.reloadUntil), connected = pl.connected }
		if pl.outfit then out.outfit = numbers(pl.outfit) end
		players[i] = out
	end
	return { version = s.version, startsAt = ms(s.startsAt), endsAt = ms(s.endsAt), serverNow = ms(s.serverNow),
		players = value.array(players), clouds = Rules.cloudsValue(s.clouds), lastSequence = s.lastSequence,
		lastEvent = s.lastEvent, over = s.over }
end

function Rules.snapshot(v: unknown): Snapshot?
	local r = record(v)
	if not r then return nil end
	local players = list(r.players, Rules.MAX_PLAYERS, function(item: unknown): Player?
		local m = record(item)
		if not m then return nil end
		local player, session, seat = integer(m.player, 0, MAX_ID), integer(m.session, 1, MAX_ID), integer(m.seat, 1, Rules.MAX_PLAYERS)
		local shown, score, reloadUntil = name(m.name), integer(m.score, -MAX_ID, MAX_ID), real(m.reloadUntil, 0, 1e9)
		local outfit = if m.outfit == nil then nil else list(m.outfit, 200, function(id: unknown): number? return integer(id, -2^31, 2^31) end)
		if not player or not session or not seat or not shown or not score or not reloadUntil or type(m.connected) ~= "boolean"
			or (m.outfit ~= nil and not outfit) then return nil end
		return { player = player, session = session, seat = seat, name = shown, outfit = outfit, score = score,
			reloadUntil = reloadUntil, connected = m.connected :: boolean }
	end)
	local clouds = Rules.clouds(r.clouds)
	local version = integer(r.version, 1, 1000)
	local startsAt, endsAt, now = real(r.startsAt, 0, 1e9), real(r.endsAt, 0, 1e9), real(r.serverNow, 0, 1e9)
	local lastSequence, lastEvent = integer(r.lastSequence, 0, MAX_ID), integer(r.lastEvent, 0, MAX_ID)
	if not players or not clouds or not version or not startsAt or not endsAt or not now or not lastSequence or not lastEvent
		or type(r.over) ~= "boolean" then return nil end
	return { version = version, startsAt = startsAt, endsAt = endsAt, serverNow = now, players = players, clouds = clouds,
		lastSequence = lastSequence, lastEvent = lastEvent, over = r.over :: boolean }
end

function Rules.shotValue(s: Shot): types.Value
	return { event = s.event, sequence = s.sequence, seat = s.seat, cloud = s.cloud, claimed = s.claimed, reason = s.reason,
		delta = s.delta, total = s.total, at = ms(s.at), reloadUntil = ms(s.reloadUntil) }
end

function Rules.shot(v: unknown): Shot?
	local r = record(v)
	if not r then return nil end
	local event, sequence, seat, cloud = integer(r.event, 1, MAX_ID), integer(r.sequence, 1, MAX_ID),
		integer(r.seat, 1, Rules.MAX_PLAYERS), integer(r.cloud, 1, MAX_ID)
	local delta, total = integer(r.delta, -1, 2), integer(r.total, -MAX_ID, MAX_ID)
	local at, reloadUntil = real(r.at, 0, 1e9), real(r.reloadUntil, 0, 1e9)
	local reason = r.reason
	if not event or not sequence or not seat or not cloud or type(r.claimed) ~= "boolean" or not delta or not total
		or not at or not reloadUntil or (reason ~= "" and reason ~= "claimed" and reason ~= "expired") then return nil end
	return { event = event, sequence = sequence, seat = seat, cloud = cloud, claimed = r.claimed :: boolean,
		reason = reason :: string, delta = delta, total = total, at = at, reloadUntil = reloadUntil }
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
		local player, shown, score = integer(r.player, 0, MAX_ID), name(r.name), integer(r.score, -MAX_ID, MAX_ID)
		local place, starlights = integer(r.place, 1, Rules.MAX_PLAYERS), integer(r.starlights, 0, 1000)
		if not player or not shown or not score or not place or not starlights then return nil end
		return { player = player, name = shown, score = score, place = place, starlights = starlights }
	end)
end

-- A shot intent: (sequence, cloud id, claimed server time or nil).
function Rules.shoot(sequence: unknown, cloud: unknown, at: unknown): (number?, number?, number?)
	return integer(sequence, 1, MAX_ID), integer(cloud, 1, MAX_ID), real(at, 0, 1e9)
end

return table.freeze(Rules)
