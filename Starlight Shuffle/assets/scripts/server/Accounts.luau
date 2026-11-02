--!strict
--@server
-- Every player's shop account (shared/Shop), kept in @moonbase/storage against
-- their account id so it follows them across sessions, places and devices:
-- what they own, what they wear, their booster tokens, running booster and
-- permanent tier, their accessibility settings, recent history, and a durable
-- record of each Stars purchase. Their Starlight balance is the leaderboard's
-- (server/Starlights): a Starlight purchase takes from it and grants the item
-- in one store operation, so both happen or neither does.
--
-- Stars stay the platform's (@moonbase/economy, `primary` currency). A Stars
-- purchase is written down first (`charging`, which also blocks any other
-- purchase until it settles), then charged with the purchase's id as the
-- platform's operation id, so asking again never charges twice, then
-- delivered. A refusal (not enough Stars) fails it; an unknown answer leaves
-- it pending, asked again (with the same id) a little later and whenever the
-- player arrives anywhere; a charge whose delivery fails is delivered again
-- the same way. A permanent booster that makes unused weekly tokens redundant
-- removes them as it is delivered (`refunding`) and pays their Stars back
-- through the platform, again under one id.
--
-- Arrivals' accounts are read for their look, which every avatar's identity
-- carries (server/People); in the lobby, the shop's messages (SHOP, BUY,
-- EQUIP, ACTIVATE, PREFS) are taken here. An account that cannot be read is
-- never replaced: the player hears ACCOUNT false and the shop stays shut.
--
-- Admins (server/Admins) get the shop's test tools (SHOP_TEST, in the lobby):
-- Starlight grants (kept apart from rewards: never boosted, "grant" in the
-- history), a simulated mini-game reward through the real award (boosted, once
-- per id: repeating the last one gives nothing), a fault for their next Stars
-- purchase (refused, an unknown answer, or a delivery that fails once: each
-- then settles the normal way), ending their running booster now or in a
-- minute, and resetting their own account. Nobody else hears of them, and
-- anyone else's SHOP_TEST is dropped.
local storage = require("@moonbase/storage")
local Economy = require("@moonbase/economy")
local types = require("@moonbase/types")
local Net = require("../shared/Net")
local Shop = require("../shared/Shop")

local RETRY = 20 -- seconds before an unsettled purchase is asked again while its player is here
local DELIVER_TRIES = 4

export type Player = types.Player
export type Host = {
	send: (player: Player, ...types.Value) -> (),
	clock: () -> number,
	after: (seconds: number, callback: () -> ()) -> () -> (),
	economy: Economy.Economy,
	-- [player]'s saved look, for their avatar.
	look: (player: Player, look: Shop.Look) -> (),
	-- [player]'s new Starlight balance (the HUD's and the leaderboard's).
	total: (player: Player, total: number) -> (),
	-- Whether shop messages are taken here (the lobby).
	shop: boolean,
	-- Whether [player] may use the test tools.
	admin: (player: Player) -> boolean,
	-- Adds a mini-game reward of [amount] (boosted) under [id]; [done] hears what it gave, nil when it failed.
	award: (player: Player, id: string, amount: number, done: (number?) -> ()) -> (),
}
export type Accounts = {
	added: (player: Player) -> (),
	removed: (player: Player) -> (),
	receive: (player: Player, kind: unknown, ...unknown) -> boolean,
	dispose: () -> (),
}

-- These bodies run on the datastore (Lua 5.1, store commands only, nothing
-- captured from this module). Multipliers are kept in tenths (10, 15, 20).

local loadOperation = storage.define({
	name = "shop_load",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, history: number}): {[string]: any}
		local member = store.string(args.player)
		local txs = {}
		for _, id in ipairs(store.SMEMBERS(store.key("pending", args.player))) do
			local tx = store.HGETALL(store.key("tx", id))
			tx.id = id
			txs[#txs + 1] = tx
		end
		return {
			balance = store.ZSCORE(store.key("starlights"), member) or 0,
			account = store.HGETALL(store.key("account", args.player)),
			owned = store.SMEMBERS(store.key("owned", args.player)),
			tokens = store.HGETALL(store.key("tokens", args.player)),
			paid = store.HGETALL(store.key("paid", args.player)),
			history = store.LRANGE(store.key("history", args.player), 0, args.history - 1),
			pending = txs,
			now = store.TIME(),
		}
	end,
})

local buyOperation = storage.define({
	name = "shop_buy_starlight",
	run = function(store: storage.Store, _context: storage.Context,
		args: {player: number, request: string, item: string, price: number}): {[string]: any}
		local done = store.key("bought", args.player, args.request)
		if store.EXISTS(done) then return {ok = true} end
		if store.SCARD(store.key("pending", args.player)) > 0 then return {refused = "busy"} end
		local owned = store.key("owned", args.player)
		if store.SISMEMBER(owned, args.item) then return {refused = "owned"} end
		local key, member = store.key("starlights"), store.string(args.player)
		local balance = store.ZSCORE(key, member) or 0
		if balance < args.price then return {refused = "funds"} end
		local now = store.TIME()
		local left = store.ZINCRBY(key, -args.price, member)
		store.SADD(owned, args.item)
		local history = store.key("history", args.player)
		store.LPUSH(history, now .. "|purchase|" .. args.item .. "|" .. args.price .. "|starlight")
		store.LTRIM(history, 0, 49)
		store.SET(done, 1)
		store.EXPIRE(done, 86400)
		return {ok = true, balance = left}
	end,
})

local beginOperation = storage.define({
	name = "shop_begin_stars",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, tx: string, item: string,
		price: number, kind: string, multiplier: number, expect: number, tokenCap: number}): {[string]: any}
		local txKey = store.key("tx", args.tx)
		local existing = store.HGET(txKey, "status")
		if existing then return {status = existing} end
		local pending = store.key("pending", args.player)
		if store.SCARD(pending) > 0 then return {refused = "busy"} end
		local account = store.key("account", args.player)
		local permanent = store.number(store.HGET(account, "perm")) or 10
		local now = store.TIME()
		if args.kind == "cosmetic" then
			if store.SISMEMBER(store.key("owned", args.player), args.item) then return {refused = "owned"} end
		elseif args.kind == "weekly" then
			if permanent >= args.multiplier then return {refused = "redundant"} end
			if store.HLEN(store.key("tokens", args.player)) >= args.tokenCap then return {refused = "tokens"} end
		else
			if permanent ~= args.expect then return {refused = "changed"} end
			if permanent >= args.multiplier then return {refused = "owned"} end
			local expires = store.number(store.HGET(account, "expires")) or 0
			local running = store.number(store.HGET(account, "activemul")) or 10
			if expires > now and running <= args.multiplier then return {refused = "active"} end
		end
		store.HSET(txKey, {player = args.player, item = args.item, price = args.price, currency = "stars", kind = args.kind,
			multiplier = args.multiplier, status = "charging", refund = 0, at = now})
		store.SADD(pending, args.tx)
		return {status = "charging"}
	end,
})

local deliverOperation = storage.define({
	name = "shop_deliver",
	run = function(store: storage.Store, _context: storage.Context, args: {tx: string, weekly: {[string]: number}}): {[string]: any}
		local txKey = store.key("tx", args.tx)
		local tx = store.HGETALL(txKey)
		if not tx.status then return {status = "missing"} end
		if tx.status ~= "charging" then return {status = tx.status, refund = store.number(tx.refund) or 0} end
		local player = tx.player
		local price = store.number(tx.price) or 0
		local multiplier = store.number(tx.multiplier) or 10
		local now = store.TIME()
		local refund = 0
		if tx.kind == "cosmetic" then
			store.SADD(store.key("owned", player), tx.item)
		elseif tx.kind == "weekly" then
			store.HSET(store.key("tokens", player), {[args.tx] = tx.item})
			store.HSET(store.key("paid", player), {[args.tx] = price})
		else
			store.HSET(store.key("account", player), {perm = multiplier})
			local tokens, paid = store.key("tokens", player), store.key("paid", player)
			local amounts = store.HGETALL(paid)
			for id, item in pairs(store.HGETALL(tokens)) do
				local tier = args.weekly[item]
				if tier and tier <= multiplier then
					refund = refund + (store.number(amounts[id]) or 0)
					store.HDEL(tokens, id)
					store.HDEL(paid, id)
				end
			end
		end
		local history = store.key("history", player)
		store.LPUSH(history, now .. "|purchase|" .. tx.item .. "|" .. price .. "|stars")
		store.LTRIM(history, 0, 49)
		local status = "delivered"
		if refund > 0 then status = "refunding" end
		store.HSET(txKey, {status = status, refund = refund, delivered = now})
		if refund == 0 then store.SREM(store.key("pending", player), args.tx) end
		return {status = status, refund = refund}
	end,
})

local settleOperation = storage.define({
	name = "shop_settle",
	-- [outcome]: "failed" (charging, refused by the platform) or "refunded" (refunding, paid back).
	run = function(store: storage.Store, _context: storage.Context, args: {tx: string, outcome: string, code: string}): {[string]: any}
		local txKey = store.key("tx", args.tx)
		local tx = store.HGETALL(txKey)
		if not tx.status then return {status = "missing"} end
		local player = tx.player
		if args.outcome == "failed" and tx.status == "charging" then
			store.HSET(txKey, {status = "failed", code = args.code})
			store.SREM(store.key("pending", player), args.tx)
			return {status = "failed"}
		end
		if args.outcome == "refunded" and tx.status == "refunding" then
			local now = store.TIME()
			store.HSET(txKey, {status = "delivered", refunded = now})
			store.SREM(store.key("pending", player), args.tx)
			local history = store.key("history", player)
			store.LPUSH(history, now .. "|refund||" .. (store.number(tx.refund) or 0) .. "|stars")
			store.LTRIM(history, 0, 49)
			return {status = "delivered"}
		end
		return {status = tx.status}
	end,
})

local equipOperation = storage.define({
	name = "shop_equip",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, slot: string, item: string, free: boolean}): {[string]: any}
		if not args.free and not store.SISMEMBER(store.key("owned", args.player), args.item) then return {refused = "unowned"} end
		store.HSET(store.key("account", args.player), {[args.slot] = args.item})
		return {ok = true}
	end,
})

local activateOperation = storage.define({
	name = "shop_activate",
	run = function(store: storage.Store, _context: storage.Context,
		args: {player: number, token: string, weekly: {[string]: number}, week: number}): {[string]: any}
		local tokens, paid, account = store.key("tokens", args.player), store.key("paid", args.player), store.key("account", args.player)
		local item = store.HGET(tokens, args.token)
		if not item then return {refused = "missing"} end
		local now = store.TIME()
		local expires = store.number(store.HGET(account, "expires")) or 0
		if expires > now then return {refused = "active"} end
		local multiplier = args.weekly[item] or 10
		local permanent = store.number(store.HGET(account, "perm")) or 10
		if permanent >= multiplier then return {refused = "redundant"} end
		store.HSET(account, {active = item, activemul = multiplier, expires = now + args.week})
		store.HDEL(tokens, args.token)
		store.HDEL(paid, args.token)
		local history = store.key("history", args.player)
		store.LPUSH(history, now .. "|activation|" .. item .. "|0|stars")
		store.LTRIM(history, 0, 49)
		return {ok = true}
	end,
})

local grantOperation = storage.define({
	name = "shop_test_grant",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, name: string, amount: number}): number
		local member = store.string(args.player)
		local total = store.ZINCRBY(store.key("starlights"), args.amount, member)
		store.HSET(store.key("names"), {[member] = args.name})
		local history = store.key("history", args.player)
		store.LPUSH(history, store.TIME() .. "|grant||" .. args.amount .. "|starlight")
		store.LTRIM(history, 0, 49)
		return total
	end,
})

local expireOperation = storage.define({
	name = "shop_test_expire",
	-- Ends the running weekly booster [after] milliseconds from now.
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, after: number}): boolean
		local account = store.key("account", args.player)
		local now = store.TIME()
		local expires = store.number(store.HGET(account, "expires")) or 0
		if expires <= now then return false end
		store.HSET(account, {expires = now + args.after})
		return true
	end,
})

local resetOperation = storage.define({
	name = "shop_test_reset",
	-- Everything the shop keeps for [player] but their Starlight (and, with [zero], that too).
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, zero: boolean}): boolean
		if args.zero then
			store.ZADD(store.key("starlights"), 0, store.string(args.player))
			return true
		end
		store.DEL(store.key("account", args.player), store.key("owned", args.player), store.key("tokens", args.player),
			store.key("paid", args.player), store.key("history", args.player), store.key("pending", args.player))
		return true
	end,
})

local prefsOperation = storage.define({
	name = "shop_prefs",
	run = function(store: storage.Store, _context: storage.Context, args: {player: number, motion: number, effects: number}): boolean
		store.HSET(store.key("account", args.player), {motion = args.motion, effects = args.effects})
		return true
	end,
})

-- Reading what the datastore gives back --------------------------------

local function record(v: unknown): {[string]: unknown}
	return if type(v) == "table" then v :: {[string]: unknown} else {}
end

local function number(v: unknown): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	return if n and n == n and math.abs(n) < 2 ^ 53 then n else nil
end

local function strings(v: unknown): {string}
	local out: {string} = {}
	if type(v) ~= "table" then return out end
	for _, s in v :: {unknown} do
		if type(s) == "string" then table.insert(out, s) end
	end
	return out
end

local function tier(v: unknown): number
	local n = number(v)
	return if n == 15 then 1.5 elseif n == 20 then 2 else 1
end

-- A Stars purchase still to settle, as the server keeps it.
type Unsettled = { id: string, item: Shop.Item, price: number, status: "charging" | "refunding", refund: number }

-- [look] with [slot] wearing [id].
local function wearing(look: Shop.Look, slot: Shop.Slot, id: string): Shop.Look
	local out = table.clone(look)
	if slot == "names" then out.names = id elseif slot == "plates" then out.plates = id else out.glows = id end
	return out
end

-- An account from shop_load's answer; nil when it is not one.
local function readAccount(v: unknown): (Shop.Account?, {Unsettled})
	local r = record(v)
	local now, balance = number(r.now), number(r.balance)
	local unsettled: {Unsettled} = {}
	if not now or not balance then return nil, unsettled end
	local fields = record(r.account)
	local owned: {[string]: boolean} = {}
	for _, id in strings(r.owned) do
		if Shop.get(id) then owned[id] = true end
	end
	local look = Shop.look(fields)
	-- Wearing what is no longer theirs (or never was) shows the default.
	for _, slot in Shop.SLOTS do
		local item = Shop.cosmetic(slot, Shop.slot(look, slot))
		if item and item.price > 0 and not owned[item.id] then look = wearing(look, slot, Shop.slot(Shop.defaultLook(), slot)) end
	end
	local tokens: {Shop.Token} = {}
	local paid = record(r.paid)
	for id, item in record(r.tokens) do
		local weekly = Shop.get(item)
		if weekly and Shop.isWeekly(weekly) and #id <= 64 then
			table.insert(tokens, { id = id, item = weekly.id, paid = math.max(0, math.floor(number(paid[id]) or 0)) })
		end
	end
	table.sort(tokens, function(a: Shop.Token, b: Shop.Token): boolean return a.id < b.id end)
	local active: Shop.Active? = nil
	local activeItem, expires = Shop.get(fields.active), number(fields.expires)
	if activeItem and Shop.isWeekly(activeItem) and expires and expires > now then
		active = { item = activeItem.id, expires = math.floor(expires) }
	end
	local pending: {Shop.Pending} = {}
	if type(r.pending) == "table" then
		for _, raw in r.pending :: {unknown} do
			local tx = record(raw)
			local item, status, id = Shop.get(tx.item), tx.status, tx.id
			if item and type(id) == "string" and (status == "charging" or status == "refunding") and #pending < 16 then
				table.insert(pending, { id = id, item = item.id, status = status :: any })
				table.insert(unsettled, { id = id, item = item, price = math.floor(number(tx.price) or 0),
					status = status :: any, refund = math.floor(number(tx.refund) or 0) })
			end
		end
	end
	local history: {Shop.Receipt} = {}
	for _, line in strings(r.history) do
		local at, kind, item, amount, currency = string.match(line, "^(%d+)|(%a+)|([^|]*)|(%d+)|(%a+)$")
		if at and (kind == "purchase" or kind == "refund" or kind == "activation" or kind == "reward" or kind == "grant")
			and (currency == "stars" or currency == "starlight") and #history < Shop.MAX_HISTORY then
			local known = if item ~= "" then Shop.get(item) else nil
			table.insert(history, { at = tonumber(at) :: number, kind = kind :: any, item = if known then known.id else nil,
				amount = tonumber(amount) :: number, currency = currency :: any })
		end
	end
	return {
		starlight = math.max(0, math.floor(balance)), owned = owned, equipped = look, tokens = tokens, active = active,
		permanent = tier(fields.perm), pending = pending, history = history,
		prefs = { motion = fields.motion == "1", effects = fields.effects == "1" }, now = math.floor(now),
	}, unsettled
end

-- Weekly booster multipliers by item id, in tenths, for the store.
local WEEKLY: {[string]: number} = {}
for _, item in Shop.items do
	if Shop.isWeekly(item) then WEEKLY[item.id] = math.round((item.multiplier or 1) * 10) end
end

-- What a refusal tells the player.
local REFUSALS: {[string]: string} = {
	busy = "A purchase is already processing.",
	owned = "Already owned.",
	funds = "Not enough Starlight.",
	redundant = "Your permanent booster already gives this bonus or better.",
	tokens = "You have plenty of unused tokens.",
	changed = "The price changed. Please review it again.",
	active = "Wait for your active weekly booster to expire before this upgrade.",
	unowned = "This cosmetic is not owned.",
	missing = "That token is no longer available.",
}

type Person = {
	player: Player,
	account: Shop.Account?,
	-- Server clock when the account was read, for the datastore's time since.
	readAt: number,
	unsettled: {Unsettled},
	busy: boolean,
	-- Purchases being charged or refunded right now, by id.
	working: {[string]: boolean},
	-- Admins: the fault their next Stars purchase meets, and their last simulated reward's id.
	fault: Shop.Fault, rewardId: string?, rewards: number,
	cancels: {() -> ()},
}

local Accounts = {}

function Accounts.new(host: Host): Accounts
	local people: {[number]: Person} = {} -- by session id
	local closed = false

	local function here(person: Person): boolean
		return not closed and people[person.player.session_id] == person and person.player.isActive
	end

	-- The datastore's clock now, as last read.
	local function now(person: Person): number
		local account = person.account
		return if account then account.now + math.floor((host.clock() - person.readAt) * 1000) else 0
	end

	local function reply(person: Person, request: string, outcome: "done" | "pending" | "refused", message: string?, refund: number?)
		if not here(person) then return end
		host.send(person.player, Net.SHOPPED, request, outcome, message or "", refund or 0)
	end

	local function tell(person: Person)
		if not here(person) or not host.shop then return end
		local account = person.account
		if account then host.send(person.player, Net.ACCOUNT, Shop.accountValue(account))
		else host.send(person.player, Net.ACCOUNT, false) end
	end

	-- Settles an unsettled purchase (defined below; the steps before it call it again).
	local settler: {settle: (person: Person, tx: Unsettled, request: string) -> ()} = { settle = function() end }
	local function settle(person: Person, tx: Unsettled, request: string) settler.settle(person, tx, request) end

	-- Reads [person]'s account again; [done] hears whether it could.
	local function load(person: Person, done: ((boolean) -> ())?)
		loadOperation:call({player = person.player.player_id, history = Shop.MAX_HISTORY}, function(result)
			if not here(person) then return end
			local account, unsettled = nil, {}
			if result.ok then account, unsettled = readAccount(result.value) end
			if not account then
				if not result.ok then print("Shop account read failed: " .. result.error.message) end
				-- An account read before stays: never replaced by nothing.
				if done then done(false) end
				return
			end
			local first = person.account == nil
			local previous = person.account
			person.account, person.readAt, person.unsettled = account, host.clock(), unsettled
			if first or (previous and (previous.equipped.names ~= account.equipped.names
				or previous.equipped.plates ~= account.equipped.plates or previous.equipped.glows ~= account.equipped.glows)) then
				host.look(person.player, account.equipped)
			end
			host.total(person.player, account.starlight)
			-- Whatever was left unsettled, wherever, settles now.
			for _, tx in unsettled do
				if not person.working[tx.id] then settle(person, tx, "") end
			end
			if done then done(true) end
		end)
	end

	-- Tells an admin in the shop what their test tools are set to.
	local function tester(person: Person)
		if not here(person) or not host.shop or not host.admin(person.player) then return end
		host.send(person.player, Net.TESTER, { sandbox = host.economy.sandbox, fault = person.fault })
	end

	local function later(person: Person, callback: () -> ())
		table.insert(person.cancels, host.after(RETRY, function()
			if here(person) then callback() end
		end))
	end

	-- Delivers a charged purchase, trying a few times; [done] hears its answer
	-- (nil when it never came).
	local function deliver(person: Person, tx: Unsettled, done: ({[string]: unknown}?) -> ())
		if person.fault == "deliver" then
			-- Admin test: this delivery fails; the next try delivers.
			person.fault = "none"
			tester(person)
			done(nil)
			return
		end
		local tries = 0
		local function try()
			tries += 1
			deliverOperation:call({tx = tx.id, weekly = WEEKLY}, function(result)
				if result.ok then done(record(result.value)); return end
				print("Shop delivery of " .. tx.id .. " failed: " .. result.error.message)
				if tries < DELIVER_TRIES then host.after(2 ^ tries, try) else done(nil) end
			end)
		end
		try()
	end

	-- Charges [tx] on the platform, unless an admin's test fault answers instead.
	local function take(person: Person, tx: Unsettled, done: (Economy.Result<boolean>) -> ())
		local fault = person.fault
		if fault == "refuse" or fault == "unknown" then
			person.fault = "none"
			tester(person)
			done({ok = false, error = {code = if fault == "refuse" then "funds" else "unavailable", message = "Admin test fault"}})
			return
		end
		host.economy.take(person.player.player_id, {primary = tx.price}, "Starlight Shuffle shop: " .. tx.item.name, tx.id, done)
	end

	-- Pays back a delivered purchase's refund, then marks it settled.
	local function refund(person: Person, tx: Unsettled, request: string)
		local player = person.player
		host.economy.grant(player.player_id, {primary = tx.refund}, "Starlight Shuffle shop: redundant booster tokens refunded",
			tx.id .. ":refund", function(result: Economy.Result<boolean>)
				if not result.ok then
					print("Shop refund of " .. tx.id .. " failed: " .. result.error.code)
					person.working[tx.id] = nil
					reply(person, request, "pending", "Your purchase is saved. Your token refund is still being processed.", tx.refund)
					later(person, function() if not person.working[tx.id] then settle(person, tx, "") end end)
					return
				end
				settleOperation:call({tx = tx.id, outcome = "refunded", code = ""}, function(_)
					person.working[tx.id] = nil
					if not here(person) then return end
					load(person, function()
						tell(person)
						reply(person, request, "done", if request == "" then "Your token refund was completed." else nil, tx.refund)
					end)
				end)
			end)
	end

	-- Charges (again, under the same id) and delivers [tx], or pays back its refund.
	settler.settle = function(person: Person, tx: Unsettled, request: string)
		if person.working[tx.id] then return end
		person.working[tx.id] = true
		if tx.status == "refunding" then refund(person, tx, request); return end
		local player = person.player
		take(person, tx, function(result: Economy.Result<boolean>)
				if not result.ok then
					local code = result.error.code
					if code == "unavailable" then
						-- It may have been charged: still pending, asked again soon.
						person.working[tx.id] = nil
						reply(person, request, "pending", "Payment pending. We're confirming it with Everskies — please don't buy it again.")
						later(person, function() if not person.working[tx.id] then settle(person, tx, "") end end)
						return
					end
					settleOperation:call({tx = tx.id, outcome = "failed", code = code}, function(_)
						person.working[tx.id] = nil
						if not here(person) then return end
						load(person, function()
							tell(person)
							reply(person, request, "refused", if code == "funds" then "Not enough Stars. No Stars were taken."
								elseif code == "restricted" then "Your account can't spend Stars right now. No Stars were taken."
								else "Purchase did not complete. No Stars were taken.")
						end)
					end)
					return
				end
				deliver(person, tx, function(answer: {[string]: unknown}?)
					if not answer then
						-- Charged, not yet delivered: tried again soon and on every arrival.
						person.working[tx.id] = nil
						reply(person, request, "pending", "Payment received. Delivering your item…")
						later(person, function() if not person.working[tx.id] then settle(person, tx, "") end end)
						return
					end
					local owed = math.floor(number(answer.refund) or 0)
					if answer.status == "refunding" and owed > 0 then
						refund(person, { id = tx.id, item = tx.item, price = tx.price, status = "refunding", refund = owed }, request)
						return
					end
					person.working[tx.id] = nil
					if not here(person) then return end
					load(person, function()
						tell(person)
						reply(person, request, "done", if request == "" then tx.item.name .. " was delivered." else nil)
					end)
				end)
			end)
	end

	local function buy(person: Person, request: string, item: Shop.Item, price: unknown, currency: unknown)
		local account = person.account
		if not account then reply(person, request, "refused", "Your account couldn't be loaded. Try again."); return end
		if item.price == 0 then reply(person, request, "refused", "Already owned."); return end
		-- A changed price or currency needs a fresh confirmation.
		if price ~= Shop.cost(account, item) or currency ~= item.currency then
			tell(person)
			reply(person, request, "refused", "The price changed. Please review it again.")
			return
		end
		local why = Shop.reason(account, item, now(person))
		if why then reply(person, request, "refused", why); return end
		local player = person.player
		person.busy = true
		if item.currency == "starlight" then
			buyOperation:call({player = player.player_id, request = request, item = item.id, price = item.price}, function(result)
				person.busy = false
				if not here(person) then return end
				local answer: {[string]: unknown} = if result.ok then record(result.value) else {}
				local refused = answer.refused
				if type(refused) == "string" then
					reply(person, request, "refused", REFUSALS[refused] or "Purchase did not complete.")
					return
				end
				-- An unknown outcome is read back: owned means it went through.
				load(person, function(read: boolean)
					tell(person)
					local now = person.account
					if now and now.owned[item.id] then reply(person, request, "done")
					elseif read then reply(person, request, "refused", "Purchase did not complete. No Starlight was taken.")
					else reply(person, request, "pending", "We couldn't confirm your purchase yet. Please reopen the shop.") end
				end)
			end)
			return
		end
		local tx = "s" .. player.player_id .. "_" .. request
		local kind = if item.category ~= "boosters" then "cosmetic" elseif item.permanent then "permanent" else "weekly"
		beginOperation:call({player = player.player_id, tx = tx, item = item.id, price = price :: number, kind = kind,
			multiplier = math.round((item.multiplier or 1) * 10), expect = math.round(account.permanent * 10),
			tokenCap = Shop.MAX_TOKENS}, function(result)
			person.busy = false
			if not here(person) then return end
			if not result.ok then
				-- Perhaps written: reading it back settles whatever is there.
				print("Shop purchase start failed: " .. result.error.message)
				load(person, function() tell(person) end)
				reply(person, request, "pending", "We couldn't confirm your purchase yet. Please don't buy it again.")
				return
			end
			local answer = record(result.value)
			local refused = answer.refused
			if type(refused) == "string" then
				reply(person, request, "refused", if refused == "funds" then "Not enough Stars." else REFUSALS[refused] or "Purchase did not complete.")
				return
			end
			local status = answer.status
			if status == "charging" or status == "refunding" then
				reply(person, request, "pending")
				settle(person, { id = tx, item = item, price = price :: number, status = status :: any, refund = 0 }, request)
			elseif status == "delivered" then
				load(person, function() tell(person); reply(person, request, "done") end)
			else
				reply(person, request, "refused", "Purchase did not complete. No Stars were taken.")
			end
		end)
	end

	local function equip(person: Person, request: string, slot: Shop.Slot, item: Shop.Item)
		local account = person.account
		if not account then reply(person, request, "refused", "Your account couldn't be loaded. Try again."); return end
		if not Shop.owned(account, item) then reply(person, request, "refused", "This cosmetic is not owned."); return end
		person.busy = true
		equipOperation:call({player = person.player.player_id, slot = slot, item = item.id, free = item.price == 0}, function(result)
			person.busy = false
			if not here(person) then return end
			local answer: {[string]: unknown} = if result.ok then record(result.value) else {}
			if answer.ok == true then
				local look = wearing(account.equipped, slot, item.id)
				account.equipped = look
				host.look(person.player, look)
				tell(person)
				reply(person, request, "done")
			else
				if not result.ok then print("Shop equip failed: " .. result.error.message) end
				-- The previous look stays, as read back.
				load(person, function() tell(person) end)
				reply(person, request, "refused", if type(answer.refused) == "string" then REFUSALS[answer.refused :: string]
					else "Couldn't save your look. Your previous look is unchanged.")
			end
		end)
	end

	local function activate(person: Person, request: string, id: string)
		local account = person.account
		if not account then reply(person, request, "refused", "Your account couldn't be loaded. Try again."); return end
		local token: Shop.Token? = nil
		for _, t in account.tokens do if t.id == id then token = t end end
		if not token then reply(person, request, "refused", "That token is no longer available."); return end
		local why = Shop.activation(account, token, now(person))
		if why then reply(person, request, "refused", why); return end
		person.busy = true
		activateOperation:call({player = person.player.player_id, token = id, weekly = WEEKLY, week = Shop.WEEK}, function(result)
			person.busy = false
			if not here(person) then return end
			local answer: {[string]: unknown} = if result.ok then record(result.value) else {}
			load(person, function()
				tell(person)
				local now = person.account
				if answer.ok == true or (now and now.active and not result.ok) then reply(person, request, "done")
				elseif type(answer.refused) == "string" then reply(person, request, "refused", REFUSALS[answer.refused :: string])
				else reply(person, request, "refused", "Couldn't activate it. Your token is still saved.") end
			end)
		end)
	end

	-- An admin's test tool [action] with [argument] (Shop.TESTS); answered as a toast (SHOPPED, no request).
	local function test(person: Person, action: string, argument: unknown)
		local player = person.player
		local function done(message: string)
			load(person, function() tell(person); tester(person); reply(person, "", "done", message) end)
		end
		local function failed(what: string, result: storage.Result<any>)
			if not result.ok then print("Shop test " .. what .. " failed: " .. result.error.message) end
			reply(person, "", "refused", "Test tool failed: " .. what .. ".")
		end
		if action == "grant" then
			local amount = if argument == 1000 or argument == 10000 then argument :: number else 1000
			grantOperation:call({player = player.player_id, name = Net.name(player.metadata, player.player_id), amount = amount},
				function(result)
					if result.ok then done("Admin test: +" .. amount .. " Starlight granted (not boosted).") else failed("grant", result) end
				end)
		elseif action == "reward" or action == "repeat_reward" then
			-- 1st place (50 + 50) or completion only (50), through the real award and its booster.
			local base = if argument == "first" then 100 else 50
			local id = person.rewardId
			if action == "reward" or not id then
				person.rewards += 1
				id = "test:" .. player.player_id .. ":" .. math.floor(host.clock() * 1000) .. ":" .. person.rewards
				person.rewardId = id
			end
			host.award(player, id :: string, base, function(given: number?)
				if given == nil then reply(person, "", "refused", "Test tool failed: reward."); return end
				done(if given == 0 then "Admin test: that reward was already given. Nothing added."
					else "Admin test: mini-game reward of " .. base .. " base Starlight gave +" .. given .. ".")
			end)
		elseif action == "fault" then
			local fault = Shop.fault(argument)
			if not fault then return end
			person.fault = fault
			tester(person)
			reply(person, "", "done", if fault == "none" then "Admin test: Stars purchases behave normally."
				else "Admin test: your next Stars purchase " .. (if fault == "refuse" then "is refused (not enough Stars)."
					elseif fault == "unknown" then "gets an unknown answer and stays pending, then settles in about " .. RETRY .. " s."
					else "is charged, but its delivery fails once; it's delivered in about " .. RETRY .. " s."))
		elseif action == "expire" or action == "expire_soon" then
			expireOperation:call({player = player.player_id, after = if action == "expire" then 0 else 60000}, function(result)
				if not result.ok then failed("booster expiry", result); return end
				done(if result.value ~= true then "Admin test: no weekly booster is running."
					elseif action == "expire" then "Admin test: your weekly booster has ended." else "Admin test: your weekly booster ends in 1 minute.")
			end)
		elseif action == "reset" or action == "zero" then
			local account = person.account
			if action == "reset" and (next(person.working) ~= nil or (account and #account.pending > 0)) then
				reply(person, "", "refused", "A purchase is still settling. Reset once it's done.")
				return
			end
			resetOperation:call({player = player.player_id, zero = action == "zero"}, function(result)
				if not result.ok then failed("reset", result); return end
				if action == "reset" then person.unsettled = {} end
				done(if action == "zero" then "Admin test: your Starlight is now 0."
					else "Admin test: your shop account was reset. Your Starlight was kept.")
			end)
		end
	end

	return {
		added = function(player: Player)
			local person: Person = { player = player, account = nil, readAt = 0, unsettled = {}, busy = false, working = {}, cancels = {},
				fault = "none", rewardId = nil, rewards = 0 }
			people[player.session_id] = person
			load(person, function() tell(person) end)
			tester(person)
		end,
		removed = function(player: Player)
			local person = people[player.session_id]
			if not person then return end
			people[player.session_id] = nil
			for _, cancel in person.cancels do cancel() end
		end,
		receive = function(player: Player, kind: unknown, ...: unknown): boolean
			if kind == Net.SHOP_TEST then
				-- Only admins, only in the lobby; anyone else's is dropped without a word.
				local person = people[player.session_id]
				local action, argument = ...
				if person and host.shop and host.admin(player) and type(action) == "string" and Shop.TESTS[action] then
					test(person, action, argument)
				end
				return true
			end
			if kind ~= Net.SHOP and kind ~= Net.BUY and kind ~= Net.EQUIP and kind ~= Net.ACTIVATE and kind ~= Net.PREFS then
				return false
			end
			local person = people[player.session_id]
			if not person or not host.shop then return true end
			if kind == Net.SHOP then
				-- Opening the shop reads the account afresh (an outfit or a purchase elsewhere).
				load(person, function(read: boolean)
					if read or not person.account then tell(person) end
				end)
				return true
			end
			if kind == Net.PREFS then
				local motion, effects = ...
				local account = person.account
				if type(motion) ~= "boolean" or type(effects) ~= "boolean" or not account then return true end
				account.prefs = { motion = motion, effects = effects }
				prefsOperation:call({player = player.player_id, motion = if motion then 1 else 0, effects = if effects then 1 else 0},
					function(result) if not result.ok then print("Shop settings save failed: " .. result.error.message) end end)
				return true
			end
			local request = Shop.request((...))
			if not request then return true end
			if person.busy then reply(person, request, "refused", "Still working on your last change."); return true end
			local _, a, b, c = ...
			if kind == Net.BUY then
				local item = Shop.get(a)
				if item then buy(person, request, item, b, c) else reply(person, request, "refused", "That item isn't available.") end
			elseif kind == Net.EQUIP then
				local slot = if a == "names" or a == "plates" or a == "glows" then a :: Shop.Slot else nil
				local item = if slot then Shop.cosmetic(slot, b) else nil
				if slot and item then equip(person, request, slot, item) else reply(person, request, "refused", "That item isn't available.") end
			elseif type(a) == "string" and #a <= 64 then
				activate(person, request, a)
			end
			return true
		end,
		dispose = function()
			closed = true
			for _, person in people do
				for _, cancel in person.cancels do cancel() end
			end
			table.clear(people)
		end,
	}
end

return table.freeze(Accounts)
