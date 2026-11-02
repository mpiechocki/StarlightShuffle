--!strict
--@server
-- Every player's Starlight balance, kept in @moonbase/storage so it outlasts
-- sessions, places and launches: one sorted set ranks players by what they
-- have (the shop, server/Accounts, spends from it), and a hash keeps the name
-- each was last seen with, for the leaderboard. A cycle awards a mini-game's
-- Starlights in one operation; its id makes a retry of the same award count
-- once. Each player's take is boosted there by their highest booster running
-- at that moment (shared/Shop, shared/Rewards) and written to their history.
local storage = require("@moonbase/storage")
local Net = require("../shared/Net")

export type Award = { player: number, name: string, amount: number }
-- What an award gave each player (boosted) and their new balances, by player id.
export type Awarded = { given: {[number]: number}, totals: {[number]: number} }
export type Starlights = {
	-- Adds each award (amounts above zero, boosted) once per [id]; calls back
	-- with what it gave, or nil when the store failed.
	award: (id: string, awards: {Award}, done: (Awarded?) -> ()) -> (),
	-- [player]'s total; nil when the store failed.
	total: (player: number, done: (number?) -> ()) -> (),
	-- The top Net.MAX_BOARD players and where [player] stands; nil when the store failed.
	board: (player: number, done: (Net.Board?) -> ()) -> (),
}

-- These bodies run on the datastore (Lua 5.1, store commands only, nothing
-- captured from this module).
local awardOperation = storage.define({
	name = "starlights_award",
	run = function(store: storage.Store, _context: storage.Context, args: {id: string, awards: {Award}}): {[string]: any}
		local totals, given = {}, {}
		local done = store.key("awarded", args.id)
		if store.EXISTS(done) then return {totals = totals, given = given} end
		local now = store.TIME()
		for _, award in ipairs(args.awards) do
			local member = store.string(award.player)
			-- The highest of the permanent tier and a running weekly booster, in tenths.
			local account = store.key("account", award.player)
			local multiplier = store.number(store.HGET(account, "perm")) or 10
			local expires = store.number(store.HGET(account, "expires")) or 0
			local weekly = store.number(store.HGET(account, "activemul")) or 10
			if expires > now and weekly > multiplier then multiplier = weekly end
			local tenths = award.amount * multiplier
			local amount = (tenths - tenths % 10) / 10
			totals[member] = store.ZINCRBY(store.key("starlights"), amount, member)
			given[member] = amount
			store.HSET(store.key("names"), {[member] = award.name})
			local history = store.key("history", award.player)
			store.LPUSH(history, now .. "|reward||" .. amount .. "|starlight")
			store.LTRIM(history, 0, 49)
		end
		store.SET(done, 1)
		store.EXPIRE(done, 86400)
		return {totals = totals, given = given}
	end,
})

local totalOperation = storage.define({
	name = "starlights_total",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number}): number
		return store.ZSCORE(store.key("starlights"), store.string(args.player)) or 0
	end,
})

local boardOperation = storage.define({
	name = "starlights_board",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, count: number}): {[string]: any}
		local key = store.key("starlights")
		local top = store.ZRANGE(key, 0, args.count - 1, {reverse = true, scores = true})
		local members = {}
		for i, row in ipairs(top) do members[i] = row.member end
		local names = {}
		if #members > 0 then names = store.HMGET(store.key("names"), members) end
		local rows = {}
		for i, row in ipairs(top) do
			rows[i] = {player = row.member, name = names[row.member] or "", starlights = row.score}
		end
		local me = store.string(args.player)
		local score = store.ZSCORE(key, me)
		local rank = nil
		if score then
			local ascending = store.ZRANK(key, me)
			if ascending then rank = store.ZCARD(key) - ascending end
		end
		return {rows = rows, mine = score or 0, rank = rank}
	end,
})

local function whole(v: unknown): number?
	if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then return nil end
	return math.max(0, math.floor(v + 0.5))
end

-- A stored player id comes back as text.
local function playerId(v: unknown): number?
	local n = if type(v) == "string" then tonumber(v) elseif type(v) == "number" then v else nil
	return if n and n == math.floor(n) and n >= 0 then n else nil
end

local Starlights = {}

function Starlights.new(): Starlights
	return {
		award = function(id: string, awards: {Award}, done: (Awarded?) -> ())
			local given: {Award} = {}
			for _, award in awards do
				local amount = whole(award.amount)
				if amount and amount > 0 then
					table.insert(given, { player = award.player, name = Net.clip(award.name), amount = amount })
				end
			end
			if #given == 0 then done({ given = {}, totals = {} }); return end
			awardOperation:call({id = id, awards = given}, function(result)
				if not result.ok then
					print("Starlights award failed: " .. result.error.message)
					done(nil)
					return
				end
				local out: Awarded = { given = {}, totals = {} }
				local answer: unknown = result.value
				local r: {[string]: unknown} = if type(answer) == "table" then answer :: {[string]: unknown} else {}
				for _, part in {"given", "totals"} do
					local values = r[part]
					if type(values) == "table" then
						for member, n in values :: {[unknown]: unknown} do
							local player, count = playerId(member), whole(n)
							if player and count then (out :: any)[part][player] = count end
						end
					end
				end
				done(out)
			end)
		end,
		total = function(player: number, done: (number?) -> ())
			totalOperation:call({player = player}, function(result)
				if not result.ok then
					print("Starlights read failed: " .. result.error.message)
					done(nil)
					return
				end
				done(whole(result.value) or 0)
			end)
		end,
		board = function(player: number, done: (Net.Board?) -> ())
			boardOperation:call({player = player, count = Net.MAX_BOARD}, function(result)
				if not result.ok then
					print("Leaderboard read failed: " .. result.error.message)
					done(nil)
					return
				end
				local raw: unknown = result.value
				local r: {[string]: unknown} = if type(raw) == "table" then raw :: {[string]: unknown} else {}
				local top: {Net.Row} = {}
				local rows: unknown = r.rows
				if type(rows) == "table" then
					for _, item in rows :: {unknown} do
						local row: {[string]: unknown} = if type(item) == "table" then item :: {[string]: unknown} else {}
						local id, count = playerId(row.player), whole(row.starlights)
						local name = if type(row.name) == "string" and row.name ~= "" then Net.clip(row.name :: string) else nil
						if id and count then
							table.insert(top, { player = id, name = name or ("Player " .. id), starlights = count })
						end
						if #top == Net.MAX_BOARD then break end
					end
				end
				local rank = whole(r.rank)
				done({ top = top, rank = if rank and rank >= 1 then rank else nil, mine = whole(r.mine) or 0 })
			end)
		end,
	}
end

return table.freeze(Starlights)
