--!strict
-- Starcatchers' tuning, rules and wire format, the same on the server and
-- every client. Everyone stands on their own floating moon and throws a small
-- hand net up into their OWN stream of drifting stars: a press throws it, a
-- release (or the top of the throw, or a catch) brings it back, and a star
-- scores only when the net gets home with it. Satellites crossing the net's
-- actual position knock the catch loose and tangle the net for a moment.
--
-- Streams: every participant's stars and satellites come from the match seed
-- and their own stream number (their seat), through an exact integer hash, so
-- the server and their client agree to the bit and nobody shares stars.
-- Normalized space: height 0 is the hand, 1 the top of a throw; x 0 is the
-- participant's own flight axis. Times are seconds since the round started
-- (`elapsed`) unless named otherwise.
--
-- Messages (the cycle's GAME channel; absolute times are the server's clock):
--   client -> server: SYNC, clientTime
--                     THROW, sequence  |  RECALL, sequence
--   server -> client: SYNC, clientTime, serverTime
--                     SNAPSHOT, snapshot  (to each player: on arrival)
--                     NET, update  (a participant's net changed: to them and
--                                   whoever shows them)
--                     REJECT, sequence  (to its sender: a throw that did not happen)
--                     RESULTS, standings
local types = require("@moonbase/types")
local value = require("@moonbase/value")

local Rules = {}

Rules.VERSION = 1 -- of CONFIG; raise it when tuning changes
Rules.SYNC = "sync"
Rules.THROW = "throw"
Rules.RECALL = "recall"
Rules.SNAPSHOT = "snapshot"
Rules.NET = "net"
Rules.REJECT = "reject"
Rules.RESULTS = "results"

Rules.CONFIG = table.freeze({
	DURATION = 60,
	PREPARATION = 8, FINAL_COUNT = 3, -- the announcement: instructions, then 3, 2, 1
	PER_WAVE = 4, WAVE = 1.2, WAVE_JITTER = 0.3, SLOT = 0.105, ITEM_JITTER = 0.05,
	FIRST = 0.8, TRAVEL = 1.5, TRAVEL_SPREAD = 0.45,
	SATELLITE_FIRST = 5.4, SATELLITE_EVERY = 4.5, SATELLITE_JITTER = 1.3,
	SATELLITE_TRAVEL = 2.2, SATELLITE_TRAVEL_SPREAD = 0.5,
	TANGLE = 1.2, -- the satellite penalty: no throw meanwhile
	RISE = 0.86, GRAVITY = 0.32, RETURN = 1.65,
	STEP = 0.04, -- the simulation's longest substep
	STAR_DX = 0.115, STAR_DH = 0.065,
	SATELLITE_DX = 0.068, SATELLITE_DH = 0.075,
	VISIBLE = 1.2, -- |x| while a star or satellite is on screen
	ARMED = 0.035, -- the net catches nothing below this height
	OUT_BOW = 0.17, OUT_BOW_TIME = 1.2, BACK_BOW = 0.18,
	MAX_STREAK_BONUS = 3,
	VALUES = table.freeze({ star = 1, gold = 3, constellation = 5 }),
	MAX_PLAYERS = 24,
})
local C = Rules.CONFIG

export type Kind = "star" | "gold" | "constellation"
export type Item = { id: number, kind: Kind, at: number, travel: number, height: number, value: number, direction: number }
export type Satellite = { id: number, at: number, travel: number, height: number, direction: number }
export type Stage = "idle" | "rising" | "reeling" | "tangled"

-- 32-bit integer multiply (exact; Luau numbers are doubles).
local function imul(a: number, b: number): number
	local ah, al = bit32.rshift(a, 16), bit32.band(a, 0xffff)
	local bh, bl = bit32.rshift(b, 16), bit32.band(b, 0xffff)
	return bit32.band(al * bl + bit32.lshift(bit32.band(ah * bl + al * bh, 0xffff), 16), 0xffffffff)
end

local function mix(x: number): number
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = imul(x, 0x7feb352d)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = imul(x, 0x846ca68b)
	return bit32.bxor(x, bit32.rshift(x, 16))
end

-- A uniform 0..1 sample for ([seed], [stream], [index], [salt]): every
-- property draws its own; the same inputs give the same number everywhere.
function Rules.random(seed: number, stream: number, index: number, salt: number): number
	local h = mix(bit32.bxor(bit32.band(seed, 0xffffffff), 0x9e3779b9))
	h = mix(bit32.bxor(h, bit32.band(stream, 0xffffffff)))
	h = mix(bit32.bxor(h, bit32.band(index, 0xffffffff)))
	h = mix(bit32.bxor(h, bit32.band(salt, 0xffffffff)))
	return h / 4294967296
end
local random = Rules.random

-- What a star of [kind] is worth.
function Rules.value(kind: Kind): number
	return if kind == "constellation" then C.VALUES.constellation elseif kind == "gold" then C.VALUES.gold else C.VALUES.star
end

-- Star [i] of a stream: four per wave (a low star, a high gold or
-- constellation, a middle and a mixed one), drifting left or right.
function Rules.item(seed: number, stream: number, i: number): Item
	local wave, slot = i // C.PER_WAVE, i % C.PER_WAVE
	local function r(salt: number): number return random(seed, stream, i, salt) end
	local roll = r(1)
	local kind: Kind = if slot == 0 then "star"
		elseif slot == 1 then (if roll < 0.18 then "constellation" else "gold")
		elseif roll < 0.12 then "constellation" elseif roll < 0.39 then "gold" else "star"
	local height = if slot == 0 then 0.27 + (r(2) - 0.5) * 0.035
		elseif slot == 1 then 0.87 + (r(2) - 0.5) * 0.05
		elseif slot == 2 then 0.57 + (r(2) - 0.5) * 0.12
		else 0.28 + r(2) * 0.44
	local at = C.FIRST + wave * C.WAVE + random(seed, stream, wave, 100) * C.WAVE_JITTER + slot * C.SLOT + r(3) * C.ITEM_JITTER
	return { id = i, kind = kind, at = at, travel = C.TRAVEL + r(4) * C.TRAVEL_SPREAD, height = height,
		value = Rules.value(kind), direction = if r(5) > 0.5 then 1 else -1 }
end

-- Satellite [i] of a stream: a hazard roughly every SATELLITE_EVERY seconds.
function Rules.satellite(seed: number, stream: number, i: number): Satellite
	local function r(salt: number): number return random(seed, stream, i, 200 + salt) end
	return { id = i, at = C.SATELLITE_FIRST + i * C.SATELLITE_EVERY + r(1) * C.SATELLITE_JITTER,
		travel = C.SATELLITE_TRAVEL + r(2) * C.SATELLITE_TRAVEL_SPREAD, height = 0.19 + r(3) * 0.49,
		direction = if r(4) > 0.5 then 1 else -1 }
end

-- Where a star or satellite is across its participant's field at [elapsed].
function Rules.x(d: { at: number, travel: number, direction: number }, elapsed: number): number
	return d.direction * (elapsed - d.at) / d.travel
end

-- Streams already worked out, by seed and stream: the field is asked for
-- every substep of every net, and a stream never changes.
type Cache = { items: {[number]: Item}, satellites: {[number]: Satellite} }
local caches: {[string]: Cache} = {}
local cached = 0

local function cacheOf(seed: number, stream: number): Cache
	local key = seed .. ":" .. stream
	local cache = caches[key]
	if not cache then
		if cached >= 128 then table.clear(caches); cached = 0 end
		cache = { items = {}, satellites = {} }
		caches[key] = cache
		cached += 1
	end
	return cache
end

-- Every star and satellite on screen at [elapsed].
function Rules.field(seed: number, stream: number, elapsed: number): ({Item}, {Satellite})
	local cache = cacheOf(seed, stream)
	local stars: {Item} = {}
	local n = math.floor(elapsed / (C.WAVE / C.PER_WAVE))
	for i = math.max(0, n - 12), n + 10 do
		local d = cache.items[i]
		if not d then d = Rules.item(seed, stream, i); cache.items[i] = d end
		if math.abs(Rules.x(d, elapsed)) <= C.VISIBLE then table.insert(stars, d) end
	end
	local satellites: {Satellite} = {}
	local m = math.floor((elapsed - C.SATELLITE_FIRST) / C.SATELLITE_EVERY)
	for i = math.max(0, m - 1), math.max(1, m + 1) do
		local d = cache.satellites[i]
		if not d then d = Rules.satellite(seed, stream, i); cache.satellites[i] = d end
		if math.abs(Rules.x(d, elapsed)) <= C.VISIBLE then table.insert(satellites, d) end
	end
	return stars, satellites
end

-- A participant's net and score. `carried` is the star in the net (not yet
-- scored); `consumed` and `struck` are the stars and satellites already used up.
export type Net = {
	stage: Stage, height: number, velocity: number, grabX: number,
	launchAt: number, reelAt: number, returnHeight: number, updatedAt: number,
	carried: Item?, tangleUntil: number,
	score: number, streak: number, reachedAt: number,
	consumed: {[number]: boolean}, struck: {[number]: boolean},
}
export type EventKind = "hook" | "bank" | "snap"
export type Event = { kind: EventKind, at: number, height: number, item: Item?, delta: number? }

function Rules.newNet(): Net
	return { stage = "idle", height = 0, velocity = 0, grabX = 0, launchAt = 0, reelAt = 0, returnHeight = 0, updatedAt = 0,
		carried = nil, tangleUntil = 0, score = 0, streak = 0, reachedAt = 0, consumed = {}, struck = {} }
end

local function clamp(n: number, low: number?, high: number?): number
	return math.clamp(n, low or 0, high or 1)
end

-- The net's x on its curved flight at [elapsed]: a bow outward, the
-- opposite bow home.
function Rules.offset(net: Net, elapsed: number): number
	if net.stage == "reeling" then
		return net.grabX - C.BACK_BOW * math.sin(math.pi * clamp(net.height / (if net.returnHeight > 0 then net.returnHeight else 1)))
	end
	if net.stage ~= "rising" then return net.grabX end
	return math.sin(clamp((elapsed - net.launchAt) / C.OUT_BOW_TIME) * math.pi) * C.OUT_BOW
end

local function startReturn(net: Net, at: number)
	net.grabX = Rules.offset(net, at)
	net.returnHeight = net.height
	net.stage = "reeling"
	net.reelAt = at
end

-- A press: throws an idle, untangled net during play. True if it flew.
function Rules.throw(net: Net, elapsed: number): boolean
	if elapsed < 0 or elapsed >= C.DURATION or net.stage ~= "idle" or elapsed < net.tangleUntil then return false end
	net.stage, net.velocity, net.launchAt, net.grabX, net.updatedAt = "rising", C.RISE, elapsed, 0, elapsed
	return true
end

-- A release: brings a rising net home early. True if it turned.
function Rules.recall(net: Net, elapsed: number): boolean
	if elapsed < 0 or elapsed >= C.DURATION or net.stage ~= "rising" then return false end
	startReturn(net, elapsed)
	net.updatedAt = elapsed
	return true
end

-- Moves [net] on to [elapsed] in substeps of at most STEP: its flight and,
-- when [seed] and [stream] are given, the catches and satellite hits in its
-- own field (calling [emit] for each). Banks only before the end; at the end
-- an unscored catch is dropped and the net comes home.
function Rules.step(net: Net, elapsed: number, seed: number?, stream: number?, emit: ((Event) -> ())?)
	local until_ = math.min(elapsed, C.DURATION)
	local cursor = math.max(0, net.updatedAt)
	while cursor < until_ do
		local nextAt = math.min(until_, cursor + C.STEP)
		local dt = nextAt - cursor
		cursor = nextAt
		if net.stage == "tangled" then
			net.height = math.max(0, net.height - dt * 1.5)
			if cursor >= net.tangleUntil then
				net.stage, net.height, net.velocity, net.grabX = "idle", 0, 0, 0
			end
			continue
		end
		if net.stage == "rising" then
			net.velocity -= C.GRAVITY * dt
			net.height = clamp(net.height + net.velocity * dt)
			if net.height >= 1 or net.velocity <= 0 then
				startReturn(net, cursor)
				net.velocity = -0.2
			end
		elseif net.stage == "reeling" then
			net.velocity += (-C.RETURN - net.velocity) * (1 - math.exp(-dt * 22))
			net.height = clamp(net.height + net.velocity * dt)
			net.grabX *= math.exp(-dt * 8)
		end
		if seed and stream and (net.stage == "rising" or net.stage == "reeling") and net.height > C.ARMED then
			local stars, satellites = Rules.field(seed, stream, cursor)
			local x = Rules.offset(net, cursor)
			local hit: Satellite? = nil
			for _, d in satellites do
				if not net.struck[d.id] and math.abs(Rules.x(d, cursor) - x) < C.SATELLITE_DX and math.abs(d.height - net.height) < C.SATELLITE_DH then
					hit = d
					break
				end
			end
			if hit then
				net.struck[hit.id] = true
				local lost = net.carried
				net.carried, net.streak = nil, 0
				net.stage, net.tangleUntil = "tangled", cursor + C.TANGLE
				if emit then emit({ kind = "snap", at = cursor, height = hit.height, item = lost }) end
				continue
			end
			if not net.carried then
				for _, d in stars do
					if not net.consumed[d.id] and math.abs(Rules.x(d, cursor) - x) < C.STAR_DX and math.abs(d.height - net.height) < C.STAR_DH then
						net.consumed[d.id] = true
						net.carried = d
						net.grabX = Rules.x(d, cursor)
						if net.stage == "rising" then
							net.height = d.height
							net.returnHeight, net.stage, net.reelAt, net.velocity = net.height, "reeling", cursor, 0
						end
						if emit then emit({ kind = "hook", at = cursor, height = net.height, item = d }) end
						break
					end
				end
			end
		end
		if net.stage == "reeling" and net.height <= 0 then
			local caught = net.carried
			if caught and cursor < C.DURATION then
				net.streak += 1
				local delta = caught.value + math.min(C.MAX_STREAK_BONUS, net.streak // 3)
				net.score += delta
				net.reachedAt = cursor
				if emit then emit({ kind = "bank", at = cursor, height = 0, item = caught, delta = delta }) end
			end
			net.carried, net.height, net.velocity, net.grabX, net.stage = nil, 0, 0, 0, "idle"
		end
	end
	net.updatedAt = math.max(net.updatedAt, until_)
	if elapsed >= C.DURATION and net.stage ~= "idle" then
		net.carried, net.height, net.velocity, net.grabX, net.stage = nil, 0, 0, 0, "idle"
	end
end

-- An unbiased in-place shuffle with [random] (0 <= random() < 1).
function Rules.shuffle<T>(list: {T}, randomFn: () -> number)
	for i = #list, 2, -1 do
		local j = math.min(i, math.floor(randomFn() * i) + 1)
		list[i], list[j] = list[j], list[i]
	end
end

-- [id]'s neighbours in the wrapping [lineup]: left and right; one rival
-- with two players; none alone.
function Rules.neighbours(lineup: {number}, id: number): (number?, number?)
	local i, n = table.find(lineup, id), #lineup
	if not i or n < 2 then return nil, nil end
	if n == 2 then return lineup[3 - i], nil end
	return lineup[(i - 2) % n + 1], lineup[i % n + 1]
end

export type Distant = { player: number, offset: number, depth: number }

-- Up to six more of the lineup in the distance: offsets -2, +2, -3, +3, -4,
-- +4, wrapping, without repeats, [id] or its neighbours. Depth 1 is nearest.
function Rules.distant(lineup: {number}, id: number): {Distant}
	local i, n = table.find(lineup, id), #lineup
	if not i then return {} end
	local left, right = Rules.neighbours(lineup, id)
	local used: {[number]: boolean} = { [id] = true }
	if left then used[left] = true end
	if right then used[right] = true end
	local out: {Distant} = {}
	for distance = 2, 4 do
		for _, sign in { -1, 1 } do
			local other = lineup[(i - 1 + sign * distance) % n + 1]
			if other and not used[other] then
				used[other] = true
				table.insert(out, { player = other, offset = sign * distance, depth = distance - 1 })
			end
		end
	end
	return out
end

-- Wire format.

export type Participant = { player: number, session: number, name: string, outfit: {number}?, stream: number }
-- A net as sent: `consumed` only to its own player.
export type Update = { player: number, version: number, net: Net, event: Event? }
export type Snapshot = { version: number, seed: number, startsAt: number, serverNow: number, lineup: {number},
	participants: {Participant}, nets: {Update}, lastSequence: number }
export type Standing = { player: number, name: string, place: number, score: number, starlights: number }

local MAX_ID = 9007199254740991
local MAX_ITEMS = 4096

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

local function numbers(ids: {number}): types.Value
	local out: {types.Value} = {}
	for i, n in ids do out[i] = n end
	return value.array(out)
end

local function ms(t: number): number return math.round(t * 1000) / 1000 end
Rules.ms = ms

-- An item travels as its stream id and index; both sides rebuild it.
local function itemFrom(seed: number, stream: number, v: unknown): Item?
	local id = integer(v, 0, MAX_ITEMS)
	return if id then Rules.item(seed, stream, id) else nil
end

local STAGES: {[string]: boolean} = { idle = true, rising = true, reeling = true, tangled = true }
local EVENTS: {[string]: boolean} = { hook = true, bank = true, snap = true }

-- [mine]: include the consumed stars (the owner's view).
function Rules.updateValue(u: Update, mine: boolean): types.Value
	local n = u.net
	local out: {[string]: types.Value} = { player = u.player, version = u.version, stage = n.stage, height = ms(n.height),
		velocity = ms(n.velocity), grabX = ms(n.grabX), launchAt = ms(n.launchAt), reelAt = ms(n.reelAt),
		returnHeight = ms(n.returnHeight), updatedAt = ms(n.updatedAt), tangleUntil = ms(n.tangleUntil),
		score = n.score, streak = n.streak }
	if n.carried then out.carried = n.carried.id end
	if mine then
		local consumed: {number} = {}
		for id in n.consumed do table.insert(consumed, id) end
		table.sort(consumed)
		out.consumed = numbers(consumed)
	end
	local e = u.event
	if e then
		local ev: {[string]: types.Value} = { kind = e.kind, at = ms(e.at), height = ms(e.height) }
		if e.item then ev.item = e.item.id end
		if e.delta then ev.delta = e.delta end
		out.event = ev
	end
	return out
end

-- An update for a participant on stream [stream] of match [seed].
function Rules.update(v: unknown, seed: number, stream: number): Update?
	local r = record(v)
	if not r then return nil end
	local player, version = integer(r.player, 0, MAX_ID), integer(r.version, 0, MAX_ID)
	local stage = r.stage
	local t: {number} = {}
	for i, key in { "height", "velocity", "grabX", "launchAt", "reelAt", "returnHeight", "updatedAt", "tangleUntil" } do
		local x = real(r[key], -1e6, 1e6)
		if not x then return nil end
		t[i] = x
	end
	local score, streak = integer(r.score, 0, MAX_ID), integer(r.streak, 0, MAX_ID)
	local carried = if r.carried == nil then nil else itemFrom(seed, stream, r.carried)
	local consumedIds = if r.consumed == nil then {} else list(r.consumed, MAX_ITEMS, function(x: unknown): number? return integer(x, 0, MAX_ITEMS) end)
	if not player or not version or type(stage) ~= "string" or not STAGES[stage :: string] or not score or not streak
		or (r.carried ~= nil and not carried) or not consumedIds then return nil end
	local consumed: {[number]: boolean} = {}
	for _, id in consumedIds :: {number} do consumed[id] = true end
	local event: Event? = nil
	if r.event ~= nil then
		local e = record(r.event)
		if not e or type(e.kind) ~= "string" or not EVENTS[e.kind :: string] then return nil end
		local at, height = real(e.at, -1e6, 1e6), real(e.height, -1e6, 1e6)
		local item = if e.item == nil then nil else itemFrom(seed, stream, e.item)
		local delta = if e.delta == nil then nil else integer(e.delta, 0, 1000)
		if not at or not height or (e.item ~= nil and not item) or (e.delta ~= nil and not delta) then return nil end
		event = { kind = e.kind :: EventKind, at = at, height = height, item = item, delta = delta }
	end
	return { player = player, version = version, event = event, net = { stage = stage :: Stage, height = t[1], velocity = t[2],
		grabX = t[3], launchAt = t[4], reelAt = t[5], returnHeight = t[6], updatedAt = t[7], tangleUntil = t[8],
		carried = carried, score = score, streak = streak, reachedAt = 0, consumed = consumed, struck = {} } }
end

function Rules.snapshotValue(s: Snapshot, viewer: number?): types.Value
	local participants: {types.Value} = {}
	for i, pt in s.participants do
		local out: {[string]: types.Value} = { player = pt.player, session = pt.session, name = pt.name, stream = pt.stream }
		if pt.outfit then out.outfit = numbers(pt.outfit) end
		participants[i] = out
	end
	local nets: {types.Value} = {}
	for i, u in s.nets do nets[i] = Rules.updateValue(u, u.player == viewer) end
	return { version = s.version, seed = s.seed, startsAt = ms(s.startsAt), serverNow = ms(s.serverNow), lineup = numbers(s.lineup),
		participants = value.array(participants), nets = value.array(nets), lastSequence = s.lastSequence }
end

function Rules.snapshot(v: unknown): Snapshot?
	local r = record(v)
	if not r then return nil end
	local version, seed, lastSequence = integer(r.version, 1, 1000), integer(r.seed, 0, 0xffffffff), integer(r.lastSequence, 0, MAX_ID)
	local startsAt, now = real(r.startsAt, 0, 1e9), real(r.serverNow, 0, 1e9)
	local lineup = list(r.lineup, C.MAX_PLAYERS * 4, function(x: unknown): number? return integer(x, 0, MAX_ID) end)
	local participants = list(r.participants, C.MAX_PLAYERS * 4, function(item: unknown): Participant?
		local m = record(item)
		if not m then return nil end
		local player, session, stream = integer(m.player, 0, MAX_ID), integer(m.session, 0, MAX_ID), integer(m.stream, 1, 4096)
		local name = if type(m.name) == "string" and #(m.name :: string) > 0 and #(m.name :: string) <= 64 then m.name :: string else nil
		local outfit = if m.outfit == nil then nil else list(m.outfit, 200, function(x: unknown): number? return integer(x, -2^31, 2^31) end)
		if not player or not session or not stream or not name or (m.outfit ~= nil and not outfit) then return nil end
		return { player = player, session = session, name = name, outfit = outfit, stream = stream }
	end)
	if not version or not seed or not lastSequence or not startsAt or not now or not lineup or not participants then return nil end
	local streams: {[number]: number} = {}
	for _, pt in participants do streams[pt.player] = pt.stream end
	local rawNets = record(r.nets)
	if not rawNets then return nil end
	local nets: {Update} = {}
	for _, raw in rawNets do
		local m = record(raw)
		local player = if m then integer(m.player, 0, MAX_ID) else nil
		local stream = if player then streams[player] else nil
		local u = if stream then Rules.update(raw, seed, stream) else nil
		if not u then return nil end
		table.insert(nets, u)
	end
	return { version = version, seed = seed, startsAt = startsAt, serverNow = now, lineup = lineup, participants = participants,
		nets = nets, lastSequence = lastSequence }
end

function Rules.standingsValue(standings: {Standing}): types.Value
	local out: {types.Value} = {}
	for i, s in standings do
		out[i] = { player = s.player, name = s.name, place = s.place, score = s.score, starlights = s.starlights }
	end
	return value.array(out)
end

function Rules.standings(v: unknown): {Standing}?
	return list(v, C.MAX_PLAYERS * 4, function(item: unknown): Standing?
		local r = record(item)
		if not r then return nil end
		local player, place, score, starlights = integer(r.player, 0, MAX_ID), integer(r.place, 1, 1000), integer(r.score, 0, MAX_ID),
			integer(r.starlights, 0, 1000)
		local name = if type(r.name) == "string" and #(r.name :: string) > 0 and #(r.name :: string) <= 64 then r.name :: string else nil
		if not player or not place or not score or not starlights or not name then return nil end
		return { player = player, name = name, place = place, score = score, starlights = starlights }
	end)
end

-- An intent: its sequence, or nil.
function Rules.sequence(a: unknown): number?
	return integer(a, 1, MAX_ID)
end

return table.freeze(Rules)
