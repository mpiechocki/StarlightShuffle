--!strict
-- Wire protocol. Every server instance is a *place*: a lobby or a cycle (the
-- mini-game cycle). Avatars are world state: the server spawns, moves and
-- replicates them (server/Arena, @moonbase/replication), each with two data
-- parts: its packed `motion` and its `identity` (whose it is, their name,
-- outfit and thumbnail). Everything else is messages:
--
--   client -> server: MOVE, report  (packed by @moonbase/prediction)
--                     LOOK, outfit
--   server -> client: HELLO, sessionId, name, place  (when you arrive)
--                     STARLIGHTS, total  (your lifetime Starlights)
--
-- Lobby (server/Lobby):
--   client -> server: START  (the Start Cycle button)  |  LEADERBOARD
--   server -> client: MOVING  |  FAILED, reason  |  LEADERBOARD, board
--
-- Lobby chat (server/Chat), as in Sky Lounge:
--   client -> server: SAY, text  |  TYPING, typing
--   server -> client: CHAT, experience?  (when you arrive: where reports go)
--                     SAY, sessionId, name, text, roles, messageId?
--                     TYPING, sessionId, typing
-- SAY goes to everyone the speaker may talk to, the sender included, with the
-- speaker's roles (Net.roles); nothing said is kept, so a joiner's chat starts
-- empty. TYPING reports when a player starts or stops writing; a SAY also ends
-- it. Where the platform moderates chat it keeps every message, and players
-- report one by its `messageId` within CHAT's `experience`; only other
-- players' copies carry it.
--
-- Cycle (server/Cycle): mini-games one after another, in a loop.
--   client -> server: PAUSE, paused  (the HUD's Pause/Play button)
--                     GAME, ...  (the current mini-game's own messages)
--   server -> client: ROUND, round  (the phase, game and time left; again on change)
--                     PAUSED, paused  |  RESULTS, results  |  MOVING
--                     GAME, gameId, ...  (the current mini-game's own messages)
-- Between mini-games the cycle takes a break in the lobby scene, where the
-- lobby chat (SAY, TYPING) is open.
-- A paused player goes back to a lobby when the current mini-game ends.
--
-- Admins (account ids in the server's startup settings; server/Admins), in
-- either place:
--   client -> server: LINEUP, includedIds  (which mini-games cycles play)
--   server -> client: ADMIN, lineup  (to admins only: on arrival, on change and
--                     as the cycle moves on)
local types = require("@moonbase/types")
local value = require("@moonbase/value")
local Movement = require("@moonbase/movement")
local Net = {}

Net.MOVE = "move"
Net.LOOK = "look"
Net.HELLO = "hello"
Net.STARLIGHTS = "starlights"
Net.START = "start"
Net.LEADERBOARD = "leaderboard"
Net.MOVING = "moving"
Net.FAILED = "failed"
Net.PAUSE = "pause"
Net.PAUSED = "paused"
Net.ROUND = "round"
Net.RESULTS = "results"
Net.GAME = "game"
Net.ADMIN = "admin"
Net.LINEUP = "lineup"
Net.CHAT = "chat"
Net.SAY = "say"
Net.TYPING = "typing"

Net.MAX_OUTFIT = 200 -- variation ids per outfit
Net.MAX_NAME = 64 -- bytes of a name in leaderboard and results messages
Net.MAX_BOARD = 20 -- rows the leaderboard lists
Net.MAX_RESULTS = 64 -- rows a round's results list
Net.MAX_CHARS = 240 -- characters per chat message
Net.CHAT_COOLDOWN = 0.7 -- seconds between one player's messages
Net.CHAT_KEEP = 50 -- messages a client's chat history keeps
Net.MAX_ROLES = 8 -- roles one player shows
Net.MAX_ROLE = 32 -- bytes of a role's name

local MAX_ID = 9007199254740991

export type Place = "lobby" | "cycle"
export type Reason = "busy" | "full" | "unavailable"
-- `intro`: the next mini-game is about to start; `playing`; `results`: it
-- ended and shows what everyone earned; `break`: a few seconds back in the
-- lobby scene, chatting, before the next one (`game` is the one coming);
-- `waiting`: nobody to play with yet.
export type Phase = "waiting" | "intro" | "playing" | "results" | "break"
-- What a cycle is doing: `game` is a Games id, `remaining` the seconds left in
-- this phase as of sending, `round` counts mini-games played here.
export type Round = { phase: Phase, game: string?, round: number, remaining: number }
export type Row = { player: number, name: string, starlights: number }
-- The top players, and where you stand (nil before your first Starlight).
export type Board = { top: {Row}, rank: number?, mine: number }
export type Results = { game: string, rows: {Row} }
-- Which mini-games cycles play (Games ids, in Games order; never empty), and
-- in a cycle the one on now and the one after it.
export type Lineup = { included: {string}, current: string?, upNext: string? }

function Net.id(v: unknown): number?
	if type(v) ~= "number" or v ~= math.floor(v) then return nil end
	return v
end

local function integer(v: unknown, low: number, high: number): number?
	if type(v) ~= "number" or v ~= math.floor(v) or v < low or v > high then return nil end
	return v
end

local function record(v: unknown): {[unknown]: unknown}?
	return if type(v) == "table" then v :: {[unknown]: unknown} else nil
end

-- A fresh copy of a dense, non-empty list of integer variation ids.
function Net.outfit(v: unknown): {number}?
	if type(v) ~= "table" then return nil end
	local items = v :: {[unknown]: unknown}
	local count = #items
	if count == 0 or count > Net.MAX_OUTFIT then return nil end
	local ids: {number} = {}
	local seen = 0
	for key, id in items do
		local index = integer(key, 1, count)
		local variation = integer(id, -2^31, 2^31)
		if not index or not variation then return nil end
		ids[index] = variation
		seen += 1
	end
	return if seen == count then ids else nil
end

-- An outfit as a message payload (message lists hold any Value).
function Net.list(ids: {number}): {types.Value}
	local values: {types.Value} = {}
	for i, id in ids do values[i] = id end
	return values
end

-- At most MAX_NAME bytes of [name], cut on a character boundary.
function Net.clip(name: string): string
	if #name <= Net.MAX_NAME then return name end
	local cut = Net.MAX_NAME + 1
	while cut > 1 and bit32.band(string.byte(name, cut), 0xC0) == 0x80 do cut -= 1 end
	return string.sub(name, 1, cut - 1)
end

-- A player's shown name: the `alias` in their host metadata.
function Net.name(metadata: unknown, playerId: number): string
	local alias = if type(metadata) == "table" then (metadata :: {[string]: unknown}).alias else nil
	return Net.clip(if type(alias) == "string" and alias ~= "" then alias else "Player " .. playerId)
end

function Net.place(v: unknown): Place?
	return if v == "lobby" or v == "cycle" then v :: Place else nil
end

function Net.reason(v: unknown): Reason?
	return if v == "busy" or v == "full" or v == "unavailable" then v :: Reason else nil
end

local PHASES: {[string]: boolean} = { waiting = true, intro = true, playing = true, results = true, ["break"] = true }

function Net.roundValue(round: Round): {[string]: types.Value}
	local out: {[string]: types.Value} = { phase = round.phase, round = round.round,
		remaining = math.max(0, math.round(round.remaining * 100) / 100) }
	if round.game then out.game = round.game end
	return out
end

function Net.round(v: unknown): Round?
	local r = record(v)
	if not r then return nil end
	local phase, game, round, remaining = r.phase, r.game, integer(r.round, 0, MAX_ID), r.remaining
	if type(phase) ~= "string" or not PHASES[phase] or not round then return nil end
	if game ~= nil and (type(game) ~= "string" or #game == 0 or #game > 64) then return nil end
	if type(remaining) ~= "number" or remaining ~= remaining or remaining < 0 or remaining > 86400 then return nil end
	return { phase = phase :: Phase, game = game :: string?, round = round, remaining = remaining }
end

local function rowValue(row: Row): {[string]: types.Value}
	return { player = row.player, name = row.name, starlights = row.starlights }
end

local function readRow(v: unknown): Row?
	local r = record(v)
	if not r then return nil end
	local player, starlights = integer(r.player, 0, MAX_ID), integer(r.starlights, 0, MAX_ID)
	local name = r.name
	if not player or not starlights or type(name) ~= "string" or #name == 0 or #name > Net.MAX_NAME then return nil end
	return { player = player, name = name, starlights = starlights }
end

-- A dense list of at most [limit] rows; an empty table is an empty list.
local function readRows(v: unknown, limit: number): {Row}?
	local items = record(v)
	if not items or #items > limit then return nil end
	local out: {Row} = {}
	local seen = 0
	for key, item in items do
		local index, row = integer(key, 1, #items), readRow(item)
		if not index or not row then return nil end
		out[index] = row
		seen += 1
	end
	return if seen == #items then out else nil
end

local function rowList(rows: {Row}): {types.Value}
	local values: {types.Value} = {}
	for i, row in rows do values[i] = rowValue(row) end
	return value.array(values)
end

function Net.boardValue(board: Board): {[string]: types.Value}
	local out: {[string]: types.Value} = { top = rowList(board.top), mine = board.mine }
	if board.rank then out.rank = board.rank end
	return out
end

function Net.board(v: unknown): Board?
	local r = record(v)
	if not r then return nil end
	local top, mine = readRows(r.top, Net.MAX_BOARD), integer(r.mine, 0, MAX_ID)
	local rank = if r.rank == nil then nil else integer(r.rank, 1, MAX_ID)
	if not top or not mine or (r.rank ~= nil and not rank) then return nil end
	return { top = top, rank = rank, mine = mine }
end

function Net.resultsValue(results: Results): {[string]: types.Value}
	return { game = results.game, rows = rowList(results.rows) }
end

function Net.results(v: unknown): Results?
	local r = record(v)
	if not r then return nil end
	local game, rows = r.game, readRows(r.rows, Net.MAX_RESULTS)
	if type(game) ~= "string" or #game == 0 or #game > 64 or not rows then return nil end
	return { game = game, rows = rows }
end

local GAME_ID_MAX = 64

local function gameId(v: unknown): string?
	return if type(v) == "string" and #v > 0 and #v <= GAME_ID_MAX then v else nil
end

-- Mini-game ids: a dense list of up to [limit] distinct ids, or nil.
function Net.gameIds(v: unknown, limit: number): {string}?
	local items = record(v)
	if not items or #items > limit then return nil end
	local out: {string} = {}
	local seen: {[string]: boolean} = {}
	local count = 0
	for key, item in items do
		local index, id = integer(key, 1, #items), gameId(item)
		if not index or not id or seen[id] then return nil end
		seen[id] = true
		out[index] = id
		count += 1
	end
	return if count == #items then out else nil
end

function Net.lineupValue(lineup: Lineup): {[string]: types.Value}
	local ids: {types.Value} = {}
	for i, id in lineup.included do ids[i] = id end
	local out: {[string]: types.Value} = { included = value.array(ids) }
	if lineup.current then out.current = lineup.current end
	if lineup.upNext then out.upNext = lineup.upNext end
	return out
end

function Net.lineup(v: unknown): Lineup?
	local r = record(v)
	if not r then return nil end
	local included = Net.gameIds(r.included, 64)
	local current = if r.current == nil then nil else gameId(r.current)
	local upNext = if r.upNext == nil then nil else gameId(r.upNext)
	if not included or #included == 0 or (r.current ~= nil and not current) or (r.upNext ~= nil and not upNext) then return nil end
	return { included = included, current = current, upNext = upNext }
end

-- A Starlights total; nil for anything else.
function Net.starlights(v: unknown): number?
	return integer(v, 0, MAX_ID)
end

-- A chat message on one line, trimmed; nil when empty, too long or not UTF-8.
function Net.text(v: unknown): string?
	if type(v) ~= "string" or #v > Net.MAX_CHARS * 4 then return nil end
	local text = string.match((string.gsub(v, "[%c%s]+", " ")), "^ ?(.-) ?$") or ""
	local length = utf8.len(text)
	if text == "" or not length or length > Net.MAX_CHARS then return nil end
	return text
end

-- An experience id as the platform makes them: eight letters, digits, `_` and
-- `-`, starting with a letter or digit; nil for anything else.
function Net.experience(v: unknown): string?
	if type(v) ~= "string" or #v ~= 8 or not string.match(v, "^%w[%w_%-]*$") then return nil end
	return v
end

-- A chat message's id as the platform keeps it: up to 64 letters, digits, `_`
-- and `-`; nil for anything else.
Net.MAX_MESSAGE_ID = 64
function Net.messageId(v: unknown): string?
	if type(v) ~= "string" or #v == 0 or #v > Net.MAX_MESSAGE_ID or not string.match(v, "^[%w_%-]+$") then return nil end
	return v
end

-- A platform role's name ("Creator I", "Moon II"): letters, digits and
-- single spaces; nil for anything else.
function Net.role(v: unknown): string?
	if type(v) ~= "string" or #v == 0 or #v > Net.MAX_ROLE then return nil end
	if not string.match(v, "^%w[%w ]*$") or string.find(v, "  ", 1, true) or string.sub(v, -1) == " " then return nil end
	return v
end

-- A player's roles as the platform shows them (`display_roles` in their host
-- metadata), most important first: the first colours their name in chat, and
-- each with an icon shows it (client/Roles). A fresh list of the valid names,
-- at most MAX_ROLES; anything else is none.
function Net.roles(v: unknown): {string}
	local out: {string} = {}
	if type(v) ~= "table" then return out end
	local items = v :: {[unknown]: unknown}
	for i = 1, #items do
		local name = Net.role(items[i])
		if name and not table.find(out, name) then table.insert(out, name) end
		if #out == Net.MAX_ROLES then break end
	end
	return out
end

-- Roles as a message payload: an array even when there are none.
function Net.roleList(roles: {string}): {types.Value}
	local values: {types.Value} = {}
	for i, name in roles do values[i] = name end
	return value.array(values)
end

-- An avatar thumbnail's media id, the platform's `avatar_id` (shown from
-- `<cdn>/media/avatar/<id>`): one URL path segment of letters, digits, `_`,
-- `-` and single dots; nil for anything else.
Net.MAX_AVATAR_ID = 128
function Net.avatarId(v: unknown): string?
	if type(v) ~= "string" or #v == 0 or #v > Net.MAX_AVATAR_ID then return nil end
	if not string.match(v, "^[%w_%-][%w_%-%.]*$") or string.find(v, "..", 1, true) then return nil end
	return v
end

-- Avatars (server/Arena): who an avatar is, its `identity` part. `avatar` is
-- their thumbnail's media id, when the platform gave one.
export type Identity = { session: number, player: number, name: string, outfit: {number}?, avatar: string? }

-- Packed identity: [varint session][varint player][varint name length][name]
-- [varint outfit count + 1, or 0 for none][zigzag varint variation ids]
-- [varint avatar length + 1, or 0 for none][avatar].
function Net.identity(identity: Identity): buffer
	local outfit, avatar = identity.outfit or {}, identity.avatar or ""
	local size = 40 + #identity.name + 5 * #outfit + #avatar
	local bytes, at = buffer.create(size), 0
	local function varint(n: number)
		while n >= 128 do buffer.writeu8(bytes, at, n % 128 + 128); at += 1; n = n // 128 end
		buffer.writeu8(bytes, at, n); at += 1
	end
	varint(identity.session); varint(identity.player)
	varint(#identity.name); buffer.writestring(bytes, at, identity.name); at += #identity.name
	varint(if identity.outfit then #outfit + 1 else 0)
	for _, id in outfit do varint(if id >= 0 then id * 2 else -id * 2 - 1) end
	varint(if identity.avatar then #avatar + 1 else 0)
	buffer.writestring(bytes, at, avatar); at += #avatar
	local packed = buffer.create(at)
	buffer.copy(packed, 0, bytes, 0, at)
	return packed
end

-- nil unless [v] is a whole, well-formed identity.
function Net.readIdentity(v: unknown): Identity?
	if type(v) ~= "buffer" then return nil end
	local bytes = v :: buffer
	local size, at = buffer.len(bytes), 0
	local function varint(): number?
		local n, scale = 0, 1
		for _ = 1, 8 do
			if at >= size then return nil end
			local byte = buffer.readu8(bytes, at); at += 1
			n += byte % 128 * scale
			if byte < 128 then return if n <= MAX_ID then n else nil end
			scale *= 128
		end
		return nil
	end
	local session, player, length = varint(), varint(), varint()
	if not session or session < 1 or not player or not length or length == 0 or length > Net.MAX_NAME * 4
		or length > size - at then return nil end
	local name = buffer.readstring(bytes, at, length)
	at += length
	local count = varint()
	-- An outfit is never empty (Net.outfit): 1 would be one.
	if not count or count == 1 or count > Net.MAX_OUTFIT + 1 then return nil end
	local outfit: {number}? = nil
	if count > 0 then
		local ids: {number} = {}
		for i = 1, count - 1 do
			local z = varint()
			if not z then return nil end
			local id = if z % 2 == 0 then z / 2 else -(z + 1) / 2
			if id < -2^31 or id > 2^31 then return nil end
			ids[i] = id
		end
		outfit = ids
	end
	local avatarLength = varint()
	if not avatarLength or avatarLength > Net.MAX_AVATAR_ID + 1 or avatarLength - 1 > size - at then return nil end
	local avatar: string? = nil
	if avatarLength > 0 then
		-- Present means valid: 1 (an empty id) is not one either.
		avatar = Net.avatarId(buffer.readstring(bytes, at, avatarLength - 1))
		at += avatarLength - 1
		if not avatar then return nil end
	end
	if at ~= size then return nil end
	return { session = session, player = player, name = name, outfit = outfit, avatar = avatar }
end

-- An avatar's `motion` part: what @moonbase/prediction needs about its pose.
function Net.motion(motion: Movement.Motion): buffer
	return Movement.encodeMotion(motion)
end

function Net.readMotion(v: unknown): Movement.Motion?
	return Movement.decodeMotion(v)
end

-- A movement report and the replication assignment generation it was made for.
function Net.readReport(v: unknown): (Movement.Report?, number?)
	local report = Movement.decodeReport(v)
	local scope = if report then report.scope else nil
	local generation = if scope and #scope == 1 then integer(scope[1], 0, MAX_ID) else nil
	if not report or not generation then return nil, nil end
	return report, generation
end

return table.freeze(Net)
