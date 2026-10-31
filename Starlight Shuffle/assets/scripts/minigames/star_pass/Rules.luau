--!strict
-- Star Pass's tuning, rules and wire format, the same on the server and every
-- client. A hot-potato game in waves: a few players hold glowing stars that
-- all burst together at the wave's burstAt; a holder must hold to charge
-- (CHARGE seconds) and then pass to one of up to three offered players. At the
-- burst every holder is out; a short recap names them; the next wave starts
-- with fewer stars for fewer players, until one is left. There is no match
-- clock: the match ends when one competitor remains.
--
-- Everyone is identified by their account id (`player`); seats are the stable
-- order (by account id) the roster was frozen in. Every change of a star's
-- holder gets a new possession number, so intents for an earlier catch of the
-- same star (even by the same player) never touch a later one.
--
-- Messages (the cycle's GAME channel; times are the server's clock, in seconds):
--   client -> server: SYNC, clientTime
--                     CHARGE, sequence, op ("begin" | "cancel" | "complete"), star, possession, attempt
--                     PASS, sequence, star, possession, targetPlayer
--   server -> client: SYNC, clientTime, serverTime
--                     SNAPSHOT, snapshot  (the match: on arrival and roster changes)
--                     WAVE, wave  |  PASSED, pass  |  ELIMINATED, event, batch
--                     CHARGED, charge  (to its sender: how a charge intent went)
--                     REJECT, sequence, reason  (to its sender: a pass that did not happen)
--                     RESULTS, standings
local types = require("@moonbase/types")
local value = require("@moonbase/value")

local Rules = {}

Rules.VERSION = 1 -- of CONFIG; raise it when tuning changes
Rules.SYNC = "sync"
Rules.CHARGE = "charge"
Rules.PASS = "pass"
Rules.SNAPSHOT = "snapshot"
Rules.WAVE = "wave"
Rules.PASSED = "passed"
Rules.ELIMINATED = "eliminated"
Rules.CHARGED = "charged"
Rules.REJECT = "reject"
Rules.RESULTS = "results"

Rules.CONFIG = table.freeze({
	PREPARATION = 10, FINAL_COUNT = 3,
	CHARGE = 0.65, -- the hold that charges a star, on every catch
	CATCH = 0.65, -- the least time a star stays before it can be passed on (runs with the charge)
	RETURN = 1.2, -- no passing straight back for this long, while anyone else can take it
	RECAP = 3.4, -- the elimination recap between waves
	MAX_STARS = 5, PER_STARS = 6, -- one star per six survivors, at most five
	WAVE_BASE = 10.5, WAVE_STEP = 0.35, WAVE_MIN = 6, WAVE_JITTER = 1.3,
	CHOICES = 3, -- players a holder may pass to
	FLIGHT = 0.32, BURST = 0.7, EXIT = 0.28, REMOVE = 0.36, REGROUP_DELAY = 0.12, REGROUP = 0.58,
	RECAP_IN = 0.35, RECAP_OUT = 0.28,
	SLACK = 0.03, -- timing noise allowed in the charge and catch checks
	COMPLETE_AFTER = 0.68, -- when a client sends its charge completion (a little past CHARGE)
	FORFEIT = 20, -- seconds a disconnected competitor keeps their place
	-- Where a star sits on its holder, as fractions of the avatar's box (no
	-- hand anchors from the avatar renderer).
	STAR_X = 0.64, STAR_Y = 0.43,
})
local C = Rules.CONFIG

Rules.MAX_PLAYERS = 64
Rules.MAX_NAME = 64

-- How many stars a wave has for [alive] survivors (always one fewer than them, at least).
function Rules.starCount(alive: number): number
	if alive < 2 then return 0 end
	return math.min(C.MAX_STARS, math.ceil(alive / C.PER_STARS), alive - 1)
end

-- A wave's length for wave [n] (from 1) and a 0..1 draw.
function Rules.waveDuration(n: number, draw: number): number
	return math.max(C.WAVE_MIN, C.WAVE_BASE - n * C.WAVE_STEP) + draw * C.WAVE_JITTER
end

-- Seconds between warning ticks with [remaining] seconds to the burst.
function Rules.tickInterval(remaining: number): number
	if remaining > 5 then return 0.8 end
	if remaining > 3 then return 0.52 end
	if remaining > 1.5 then return 0.32 end
	return 0.17
end

-- Who [sender] may pass to: survivors in seat order ([survivors] are player
-- ids), never themselves or anyone holding a star, and not the previous
-- holder while [returning] unless nobody else can take it; rotated by the
-- star's moves, the wave and the sender's place, the first CHOICES. [keep] are
-- the choices shown until now: those still eligible stay in their slots and
-- only emptied slots are refilled, so buttons do not jump under a finger.
function Rules.targets(survivors: {number}, holders: {[number]: boolean}, sender: number, previous: number?,
	returning: boolean, moveCount: number, wave: number, keep: {number}?): {number}
	local eligible: {number} = {}
	for _, id in survivors do
		if id ~= sender and not holders[id] then table.insert(eligible, id) end
	end
	if returning and previous and #eligible > 1 then
		local at = table.find(eligible, previous)
		if at then table.remove(eligible, at) end
	end
	local count = #eligible
	if count == 0 then return {} end
	local senderIndex = (table.find(survivors, sender) or 1) - 1
	local shift = (moveCount * 7 + wave * 3 + senderIndex) % count
	local rotated: {number} = {}
	for i = 1, count do rotated[i] = eligible[(shift + i - 1) % count + 1] end
	local open: {[number]: boolean} = {}
	for _, id in eligible do open[id] = true end
	local slots: {number | false} = {}
	local used: {[number]: boolean} = {}
	for i = 1, C.CHOICES do
		local kept = if keep then keep[i] else nil
		if kept and open[kept] and not used[kept] then slots[i], used[kept] = kept, true else slots[i] = false end
	end
	for _, id in rotated do
		if not used[id] then
			for i = 1, C.CHOICES do
				if slots[i] == false then slots[i], used[id] = id, true; break end
			end
		end
	end
	local out: {number} = {}
	for i = 1, C.CHOICES do
		local slot = slots[i]
		if slot then table.insert(out, slot) end
	end
	return out
end

export type Competitor = { player: number, seat: number, alive: boolean, eliminatedWave: number?, passes: number }

-- Final order: survivors first (more passes, then seat), then the eliminated
-- by later wave, then more passes, then seat.
function Rules.rank(competitors: {Competitor}): {Competitor}
	local out = table.clone(competitors)
	table.sort(out, function(a: Competitor, b: Competitor): boolean
		if a.alive ~= b.alive then return a.alive end
		local aw, bw = a.eliminatedWave or math.huge, b.eliminatedWave or math.huge
		if aw ~= bw then return aw > bw end
		if a.passes ~= b.passes then return a.passes > b.passes end
		return a.seat < b.seat
	end)
	return out
end

-- Wire format.

export type Player = { player: number, session: number, seat: number, name: string, outfit: {number}?, alive: boolean,
	connected: boolean, passes: number, eliminatedWave: number? }
export type Star = { id: number, holder: number, previous: number?, possession: number, receivedAt: number,
	moveCount: number, charged: boolean, choices: {number} }
export type Batch = { id: number, wave: number, players: {number}, at: number, nextAt: number, survivors: number, final: boolean }
export type Phase = "countdown" | "playing" | "recap" | "over"
export type Snapshot = { version: number, phase: Phase, startsAt: number, serverNow: number, wave: number, burstAt: number,
	nextWaveAt: number, players: {Player}, stars: {Star}, batch: Batch?, lastEvent: number, lastSequence: number,
	charging: number? }
export type Wave = { event: number, wave: number, startedAt: number, burstAt: number, stars: {Star} }
export type Passed = { event: number, star: number, from: number, to: number, possession: number, at: number,
	passes: number, stars: {Star} }
export type Charged = { sequence: number, star: number, possession: number, attempt: number,
	status: "started" | "charged" | "cancelled" | "rejected", reason: string }
export type Standing = { player: number, name: string, place: number, passes: number, wave: number?, starlights: number }

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

local function numbers(ids: {number}): {types.Value}
	local out: {types.Value} = {}
	for i, n in ids do out[i] = n end
	return value.array(out)
end

local function ids(v: unknown, limit: number): {number}?
	return list(v, limit, function(item: unknown): number? return integer(item, 0, MAX_ID) end)
end

local function ms(t: number): number return math.round(t * 1000) / 1000 end
Rules.ms = ms

function Rules.starValue(s: Star): types.Value
	local out: {[string]: types.Value} = { id = s.id, holder = s.holder, possession = s.possession, receivedAt = ms(s.receivedAt),
		moveCount = s.moveCount, charged = s.charged, choices = numbers(s.choices) }
	if s.previous then out.previous = s.previous end
	return out
end

function Rules.star(v: unknown): Star?
	local r = record(v)
	if not r then return nil end
	local id, holder, possession = integer(r.id, 1, 64), integer(r.holder, 0, MAX_ID), integer(r.possession, 1, MAX_ID)
	local receivedAt, moveCount = real(r.receivedAt, 0, 1e9), integer(r.moveCount, 0, MAX_ID)
	local previous = if r.previous == nil then nil else integer(r.previous, 0, MAX_ID)
	local choices = ids(r.choices, C.CHOICES)
	if not id or not holder or not possession or not receivedAt or not moveCount or type(r.charged) ~= "boolean"
		or not choices or (r.previous ~= nil and not previous) then return nil end
	return { id = id, holder = holder, previous = previous, possession = possession, receivedAt = receivedAt,
		moveCount = moveCount, charged = r.charged :: boolean, choices = choices }
end

local function starsValue(stars: {Star}): types.Value
	local out: {types.Value} = {}
	for i, s in stars do out[i] = Rules.starValue(s) end
	return value.array(out)
end

local function starsOf(v: unknown): {Star}?
	return list(v, C.MAX_STARS, Rules.star)
end

function Rules.batchValue(b: Batch): types.Value
	return { id = b.id, wave = b.wave, players = numbers(b.players), at = ms(b.at), nextAt = ms(b.nextAt),
		survivors = b.survivors, final = b.final }
end

function Rules.batch(v: unknown): Batch?
	local r = record(v)
	if not r then return nil end
	local id, wave, players = integer(r.id, 1, MAX_ID), integer(r.wave, 1, MAX_ID), ids(r.players, Rules.MAX_PLAYERS)
	local at, nextAt, survivors = real(r.at, 0, 1e9), real(r.nextAt, 0, 1e9), integer(r.survivors, 0, Rules.MAX_PLAYERS)
	if not id or not wave or not players or not at or not nextAt or not survivors or type(r.final) ~= "boolean" then return nil end
	return { id = id, wave = wave, players = players, at = at, nextAt = nextAt, survivors = survivors, final = r.final :: boolean }
end

local PHASES: {[string]: boolean} = { countdown = true, playing = true, recap = true, over = true }

function Rules.snapshotValue(s: Snapshot): types.Value
	local players: {types.Value} = {}
	for i, pl in s.players do
		local out: {[string]: types.Value} = { player = pl.player, session = pl.session, seat = pl.seat, name = pl.name,
			alive = pl.alive, connected = pl.connected, passes = pl.passes }
		if pl.outfit then out.outfit = numbers(pl.outfit) end
		if pl.eliminatedWave then out.eliminatedWave = pl.eliminatedWave end
		players[i] = out
	end
	local out: {[string]: types.Value} = { version = s.version, phase = s.phase, startsAt = ms(s.startsAt), serverNow = ms(s.serverNow),
		wave = s.wave, burstAt = ms(s.burstAt), nextWaveAt = ms(s.nextWaveAt), players = value.array(players),
		stars = starsValue(s.stars), lastEvent = s.lastEvent, lastSequence = s.lastSequence }
	if s.batch then out.batch = Rules.batchValue(s.batch) end
	if s.charging then out.charging = s.charging end
	return out
end

function Rules.snapshot(v: unknown): Snapshot?
	local r = record(v)
	if not r then return nil end
	local players = list(r.players, Rules.MAX_PLAYERS, function(item: unknown): Player?
		local m = record(item)
		if not m then return nil end
		local player, session, seat = integer(m.player, 0, MAX_ID), integer(m.session, 1, MAX_ID), integer(m.seat, 1, Rules.MAX_PLAYERS)
		local shown, passes = name(m.name), integer(m.passes, 0, MAX_ID)
		local wave = if m.eliminatedWave == nil then nil else integer(m.eliminatedWave, 1, MAX_ID)
		local outfit = if m.outfit == nil then nil else list(m.outfit, 200, function(id: unknown): number? return integer(id, -2^31, 2^31) end)
		if not player or not session or not seat or not shown or not passes or type(m.alive) ~= "boolean"
			or type(m.connected) ~= "boolean" or (m.outfit ~= nil and not outfit) or (m.eliminatedWave ~= nil and not wave) then return nil end
		return { player = player, session = session, seat = seat, name = shown, outfit = outfit, alive = m.alive :: boolean,
			connected = m.connected :: boolean, passes = passes, eliminatedWave = wave }
	end)
	local phase = r.phase
	local stars = starsOf(r.stars)
	local version, wave = integer(r.version, 1, 1000), integer(r.wave, 0, MAX_ID)
	local startsAt, now, burstAt, nextWaveAt = real(r.startsAt, 0, 1e9), real(r.serverNow, 0, 1e9), real(r.burstAt, 0, 1e9), real(r.nextWaveAt, 0, 1e9)
	local lastEvent, lastSequence = integer(r.lastEvent, 0, MAX_ID), integer(r.lastSequence, 0, MAX_ID)
	local batch = if r.batch == nil then nil else Rules.batch(r.batch)
	local charging = if r.charging == nil then nil else integer(r.charging, 1, MAX_ID)
	if not players or type(phase) ~= "string" or not PHASES[phase] or not stars or not version or not wave or not startsAt or not now
		or not burstAt or not nextWaveAt or not lastEvent or not lastSequence or (r.batch ~= nil and not batch)
		or (r.charging ~= nil and not charging) then return nil end
	return { version = version, phase = phase :: Phase, startsAt = startsAt, serverNow = now, wave = wave, burstAt = burstAt,
		nextWaveAt = nextWaveAt, players = players, stars = stars, batch = batch, lastEvent = lastEvent, lastSequence = lastSequence,
		charging = charging }
end

function Rules.waveValue(w: Wave): types.Value
	return { event = w.event, wave = w.wave, startedAt = ms(w.startedAt), burstAt = ms(w.burstAt), stars = starsValue(w.stars) }
end

function Rules.wave(v: unknown): Wave?
	local r = record(v)
	if not r then return nil end
	local event, wave, startedAt, burstAt = integer(r.event, 1, MAX_ID), integer(r.wave, 1, MAX_ID), real(r.startedAt, 0, 1e9), real(r.burstAt, 0, 1e9)
	local stars = starsOf(r.stars)
	if not event or not wave or not startedAt or not burstAt or not stars then return nil end
	return { event = event, wave = wave, startedAt = startedAt, burstAt = burstAt, stars = stars }
end

function Rules.passedValue(p: Passed): types.Value
	return { event = p.event, star = p.star, from = p.from, to = p.to, possession = p.possession, at = ms(p.at), passes = p.passes,
		stars = starsValue(p.stars) }
end

function Rules.passed(v: unknown): Passed?
	local r = record(v)
	if not r then return nil end
	local event, star, from, to = integer(r.event, 1, MAX_ID), integer(r.star, 1, 64), integer(r.from, 0, MAX_ID), integer(r.to, 0, MAX_ID)
	local possession, at, passes = integer(r.possession, 1, MAX_ID), real(r.at, 0, 1e9), integer(r.passes, 0, MAX_ID)
	local stars = starsOf(r.stars)
	if not event or not star or not from or not to or not possession or not at or not passes or not stars then return nil end
	return { event = event, star = star, from = from, to = to, possession = possession, at = at, passes = passes, stars = stars }
end

local STATUSES: {[string]: boolean} = { started = true, charged = true, cancelled = true, rejected = true }

function Rules.chargedValue(c: Charged): types.Value
	return { sequence = c.sequence, star = c.star, possession = c.possession, attempt = c.attempt, status = c.status, reason = c.reason }
end

function Rules.charged(v: unknown): Charged?
	local r = record(v)
	if not r then return nil end
	local sequence, star, possession, attempt = integer(r.sequence, 1, MAX_ID), integer(r.star, 0, 64), integer(r.possession, 0, MAX_ID),
		integer(r.attempt, 0, MAX_ID)
	if not sequence or not star or not possession or not attempt or type(r.status) ~= "string" or not STATUSES[r.status :: string]
		or type(r.reason) ~= "string" then return nil end
	return { sequence = sequence, star = star, possession = possession, attempt = attempt, status = r.status :: any, reason = r.reason :: string }
end

function Rules.standingsValue(standings: {Standing}): types.Value
	local out: {types.Value} = {}
	for i, s in standings do
		local row: {[string]: types.Value} = { player = s.player, name = s.name, place = s.place, passes = s.passes, starlights = s.starlights }
		if s.wave then row.wave = s.wave end
		out[i] = row
	end
	return value.array(out)
end

function Rules.standings(v: unknown): {Standing}?
	return list(v, Rules.MAX_PLAYERS, function(item: unknown): Standing?
		local r = record(item)
		if not r then return nil end
		local player, shown, place = integer(r.player, 0, MAX_ID), name(r.name), integer(r.place, 1, Rules.MAX_PLAYERS)
		local passes, starlights = integer(r.passes, 0, MAX_ID), integer(r.starlights, 0, 1000)
		local wave = if r.wave == nil then nil else integer(r.wave, 1, MAX_ID)
		if not player or not shown or not place or not passes or not starlights or (r.wave ~= nil and not wave) then return nil end
		return { player = player, name = shown, place = place, passes = passes, wave = wave, starlights = starlights }
	end)
end

-- A charge intent: (sequence, op, star, possession, attempt) or nils.
function Rules.chargeIntent(a: unknown, b: unknown, c: unknown, d: unknown, e: unknown): (number?, string?, number?, number?, number?)
	local sequence, star, possession, attempt = integer(a, 1, MAX_ID), integer(c, 1, 64), integer(d, 1, MAX_ID), integer(e, 1, MAX_ID)
	local op = if b == "begin" or b == "cancel" or b == "complete" then b :: string else nil
	if not sequence or not op or not star or not possession or not attempt then return nil, nil, nil, nil, nil end
	return sequence, op, star, possession, attempt
end

-- A pass intent: (sequence, star, possession, target) or nils.
function Rules.passIntent(a: unknown, b: unknown, c: unknown, d: unknown): (number?, number?, number?, number?)
	local sequence, star, possession, target = integer(a, 1, MAX_ID), integer(b, 1, 64), integer(c, 1, MAX_ID), integer(d, 0, MAX_ID)
	if not sequence or not star or not possession or not target then return nil, nil, nil, nil end
	return sequence, star, possession, target
end

return table.freeze(Rules)
