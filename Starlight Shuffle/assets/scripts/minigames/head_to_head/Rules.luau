--!strict
-- Head to Head's rules and wire format, the same on the server and every client.
--
-- A round's *pool* is the avatar heads its tiles cycle through, in a fixed
-- order: every participant's own head, plus approved library heads until there
-- are POOL_SIZE distinct identities (none when there are that many players or
-- more). Each head keeps one outline colour all round. The *reference* is nine
-- cells drawn from the pool (repeats allowed). A *canvas* is nine cells, 0 for
-- empty, else a pool position; tapping a cell advances it to the next head in
-- the pool's order, the first tap on an empty cell picks the first head, and
-- after the last it wraps to the first (never back to empty).
--
-- Messages (the cycle's GAME channel; see server/Minigame and client/Minigame):
--   server -> client: SETUP, setup  |  START, start  |  CANVAS, canvas
--                     PROGRESS, progress  |  RESULTS, results
--   client -> server: TAP, sequence, cell
-- A tap's sequence counts up from 1 for each player; the server applies each
-- sequence once and in order, and answers with that player's canvas and the
-- last sequence it took, so the client can reconcile what it showed early.
local types = require("@moonbase/types")
local value = require("@moonbase/value")

local Rules = {}

Rules.SETUP = "setup"
Rules.START = "start"
Rules.CANVAS = "canvas"
Rules.PROGRESS = "progress"
Rules.RESULTS = "results"
Rules.TAP = "tap"

Rules.SIZE = 3 -- the board is SIZE x SIZE
Rules.CELLS = 9
Rules.POOL_SIZE = 8 -- distinct heads a round has at least
Rules.LIBRARY = 8 -- approved library heads (assets/textures/head_to_head)
Rules.PLACES = 3 -- podium places
Rules.MAX_POOL = 64
Rules.MAX_NAME = 64
-- Starlights for 1st, 2nd and 3rd.
Rules.AWARDS = table.freeze({ 5, 3, 2 })

-- Outline colours (0xRRGGBB), one per pool position; a pool larger than this
-- list gets evenly spread hues after it.
local COLORS = { 0xff7eb6, 0xb9a3ff, 0x7fdcd2, 0x6fa8ff, 0xffd166, 0x9be38a, 0xffa477, 0xe07bff,
	0x5fd0ff, 0xff6b6b, 0xc4f08a, 0xf2b8ff }

local MAX_ID = 9007199254740991

-- A head: a participating player's (their account id, shown name and outfit),
-- or an approved library head (1..LIBRARY).
export type Head = { kind: "player", player: number, name: string, outfit: {number}? } | { kind: "library", library: number }
export type Entry = { head: Head, color: number }
export type Participant = { player: number, session: number, name: string }
export type Setup = { pool: {Entry}, participants: {Participant}, startsIn: number, duration: number }
export type Start = { reference: {number}, remaining: number }
export type Canvas = { cells: {number}, ack: number, done: boolean, time: number? }
export type Progress = { player: number, matched: number, done: boolean, time: number?, connected: boolean }
export type Place = { player: number, name: string, time: number, place: number, starlights: number }

local function hue(i: number, n: number): number
	-- Evenly spread pastel hues for pools past the fixed colours.
	local h = (i / n) % 1
	local function channel(offset: number): number
		local k = (offset + h * 6) % 6
		local v = 1 - math.max(0, math.min(k, 4 - k, 1)) * 0.55
		return math.floor(v * 255 + 0.5)
	end
	return channel(5) * 65536 + channel(3) * 256 + channel(1)
end

function Rules.color(position: number, size: number): number
	return COLORS[position] or hue(position - #COLORS, math.max(1, size - #COLORS))
end

-- Fisher-Yates over a copy; [random](n) returns an integer in [1, n].
local function shuffled<T>(items: {T}, random: (number) -> number): {T}
	local out = table.clone(items)
	for i = #out, 2, -1 do
		local j = random(i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- The round's pool: every participant's head and, below POOL_SIZE, distinct
-- library heads to fill it, in a random fixed order, each with its colour.
function Rules.pool(players: {Head}, random: (number) -> number): {Entry}
	local heads: {Head} = table.clone(players)
	if #heads < Rules.POOL_SIZE then
		local library: {number} = {}
		for i = 1, Rules.LIBRARY do library[i] = i end
		library = shuffled(library, random)
		for i = 1, math.min(Rules.POOL_SIZE - #heads, #library) do
			local head: Head = { kind = "library", library = library[i] }
			table.insert(heads, head)
		end
	end
	heads = shuffled(heads, random)
	local pool: {Entry} = {}
	for i, head in heads do pool[i] = { head = head, color = Rules.color(i, #heads) } end
	return pool
end

-- Nine cells drawn from a pool of [size] heads; repeats allowed.
function Rules.reference(size: number, random: (number) -> number): {number}
	local cells: {number} = {}
	for i = 1, Rules.CELLS do cells[i] = random(size) end
	return cells
end

function Rules.empty(): {number}
	return table.create(Rules.CELLS, 0)
end

-- What a tap makes of a cell holding [current] in a pool of [size].
function Rules.advance(current: number, size: number): number
	return current % size + 1
end

function Rules.matched(canvas: {number}, reference: {number}): number
	local count = 0
	for i = 1, Rules.CELLS do
		if canvas[i] ~= 0 and canvas[i] == reference[i] then count += 1 end
	end
	return count
end

export type Finish = { player: number, name: string, time: number, sequence: number }

-- Completed boards, fastest first; equal times by the server's completion order.
function Rules.rank(finishes: {Finish}): {Finish}
	local out = table.clone(finishes)
	table.sort(out, function(a: Finish, b: Finish): boolean
		if a.time ~= b.time then return a.time < b.time end
		return a.sequence < b.sequence
	end)
	return out
end

-- Wire format: payloads and their validators.

local function integer(v: unknown, low: number, high: number): number?
	if type(v) ~= "number" or v ~= math.floor(v) or v < low or v > high then return nil end
	return v
end

local function seconds(v: unknown): number?
	if type(v) ~= "number" or v ~= v or v < 0 or v > 86400 then return nil end
	return v
end

local function record(v: unknown): {[unknown]: unknown}?
	return if type(v) == "table" then v :: {[unknown]: unknown} else nil
end

-- A dense list of [read] items, at most [limit]; an empty table is an empty list.
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

local function outfit(v: unknown): {number}?
	return list(v, 200, function(item: unknown): number? return integer(item, -2^31, 2^31) end)
end

function Rules.setupValue(setup: Setup): types.Value
	local pool: {types.Value} = {}
	for i, entry in setup.pool do
		local head = entry.head
		local out: {[string]: types.Value} = { color = entry.color }
		if head.kind == "player" then
			out.kind, out.player, out.name = "player", head.player, head.name
			if head.outfit then out.outfit = numbers(head.outfit) end
		else
			out.kind, out.library = "library", head.library
		end
		pool[i] = out
	end
	local participants: {types.Value} = {}
	for i, p in setup.participants do participants[i] = { player = p.player, session = p.session, name = p.name } end
	return { pool = value.array(pool), participants = value.array(participants),
		startsIn = math.round(setup.startsIn * 1000) / 1000, duration = setup.duration }
end

function Rules.setup(v: unknown): Setup?
	local r = record(v)
	if not r then return nil end
	local pool = list(r.pool, Rules.MAX_POOL, function(item: unknown): Entry?
		local e = record(item)
		if not e then return nil end
		local color = integer(e.color, 0, 0xffffff)
		if not color then return nil end
		if e.kind == "player" then
			local player, shown = integer(e.player, 0, MAX_ID), name(e.name)
			local worn = if e.outfit == nil then nil else outfit(e.outfit)
			if not player or not shown or (e.outfit ~= nil and not worn) then return nil end
			return { head = { kind = "player", player = player, name = shown, outfit = worn }, color = color }
		elseif e.kind == "library" then
			local library = integer(e.library, 1, Rules.LIBRARY)
			if not library then return nil end
			return { head = { kind = "library", library = library }, color = color }
		end
		return nil
	end)
	local participants = list(r.participants, Rules.MAX_POOL, function(item: unknown): Participant?
		local p = record(item)
		if not p then return nil end
		local player, session, shown = integer(p.player, 0, MAX_ID), integer(p.session, 1, MAX_ID), name(p.name)
		if not player or not session or not shown then return nil end
		return { player = player, session = session, name = shown }
	end)
	local startsIn, duration = seconds(r.startsIn), seconds(r.duration)
	if not pool or #pool == 0 or not participants or not startsIn or not duration then return nil end
	return { pool = pool, participants = participants, startsIn = startsIn, duration = duration }
end

local function cells(v: unknown, size: number, empty: boolean): {number}?
	local out = list(v, Rules.CELLS, function(item: unknown): number? return integer(item, if empty then 0 else 1, size) end)
	return if out and #out == Rules.CELLS then out else nil
end

function Rules.startValue(start: Start): types.Value
	return { reference = numbers(start.reference), remaining = math.round(start.remaining * 1000) / 1000 }
end

function Rules.start(v: unknown, size: number): Start?
	local r = record(v)
	if not r then return nil end
	local reference, remaining = cells(r.reference, size, false), seconds(r.remaining)
	if not reference or not remaining then return nil end
	return { reference = reference, remaining = remaining }
end

function Rules.canvasValue(canvas: Canvas): types.Value
	local out: {[string]: types.Value} = { cells = numbers(canvas.cells), ack = canvas.ack, done = canvas.done }
	if canvas.time then out.time = canvas.time end
	return out
end

function Rules.canvas(v: unknown, size: number): Canvas?
	local r = record(v)
	if not r then return nil end
	local board, ack, done = cells(r.cells, size, true), integer(r.ack, 0, MAX_ID), r.done
	local time = if r.time == nil then nil else seconds(r.time)
	if not board or not ack or type(done) ~= "boolean" or (r.time ~= nil and not time) then return nil end
	return { cells = board, ack = ack, done = done, time = time }
end

function Rules.progressValue(rows: {Progress}): types.Value
	local out: {types.Value} = {}
	for i, row in rows do
		local item: {[string]: types.Value} = { player = row.player, matched = row.matched, done = row.done, connected = row.connected }
		if row.time then item.time = row.time end
		out[i] = item
	end
	return value.array(out)
end

function Rules.progress(v: unknown): {Progress}?
	return list(v, Rules.MAX_POOL, function(item: unknown): Progress?
		local r = record(item)
		if not r then return nil end
		local player, matched = integer(r.player, 0, MAX_ID), integer(r.matched, 0, Rules.CELLS)
		local time = if r.time == nil then nil else seconds(r.time)
		if not player or not matched or type(r.done) ~= "boolean" or type(r.connected) ~= "boolean"
			or (r.time ~= nil and not time) then return nil end
		return { player = player, matched = matched, done = r.done :: boolean, time = time, connected = r.connected :: boolean }
	end)
end

function Rules.resultsValue(podium: {Place}): types.Value
	local out: {types.Value} = {}
	for i, row in podium do
		out[i] = { player = row.player, name = row.name, time = row.time, place = row.place, starlights = row.starlights }
	end
	return value.array(out)
end

function Rules.results(v: unknown): {Place}?
	local podium = list(v, Rules.PLACES, function(item: unknown): Place?
		local r = record(item)
		if not r then return nil end
		local player, shown, time = integer(r.player, 0, MAX_ID), name(r.name), seconds(r.time)
		local place, starlights = integer(r.place, 1, Rules.PLACES), integer(r.starlights, 0, 1000)
		if not player or not shown or not time or not place or not starlights then return nil end
		return { player = player, name = shown, time = time, place = place, starlights = starlights }
	end)
	return podium
end

-- A tap: (sequence, cell), or nil.
function Rules.tap(sequence: unknown, cell: unknown): (number?, number?)
	local s, c = integer(sequence, 1, MAX_ID), integer(cell, 1, Rules.CELLS)
	if not s or not c then return nil, nil end
	return s, c
end

return table.freeze(Rules)
