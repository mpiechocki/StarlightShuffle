--!strict
-- The lobby shop's catalogue and rules, shared by the server (which decides)
-- and the client (which shows). Four tabs: Names (the name's colour or an
-- animated effect: one slot), Nameplates (a background behind the name: one
-- slot), Avatar Glow (one slot) and Boosters (more Starlight from playing).
-- Starlight (earned in the mini-games, the leaderboard's balance) buys the
-- static cosmetics; Stars (the player's Everskies currency) buy the animated
-- ones and the boosters. Every item has a stable id: renaming it or changing
-- its price never touches what players own.
--
-- Boosters multiply what a mini-game pays (shared/Rewards), never Stars,
-- refunds or grants, and never stack: the highest active multiplier applies.
-- A weekly booster buys an unused token, activated later for seven days in a
-- row (offline too); one runs at a time. A permanent booster applies at once,
-- for good; only the highest tier counts, and Eternal Radiance upgrades to
-- Eternal Supernova for the difference. Buying a permanent booster refunds
-- the unused weekly tokens it makes redundant, at what they cost.
--
-- An Account is what the server tells a player about theirs (ACCOUNT, see
-- Shop.accountValue); times are the datastore's clock, in milliseconds.
local types = require("@moonbase/types")
local value = require("@moonbase/value")

export type Category = "names" | "plates" | "glows" | "boosters"
export type Slot = "names" | "plates" | "glows"
export type Currency = "starlight" | "stars"
export type Filter = "all" | "starlight" | "stars" | "owned"
export type Item = {
	read id: string, read category: Category, read name: string, read currency: Currency, read price: number,
	read animated: boolean, read description: string,
	-- Boosters: the multiplier, and seven days (weekly) or for good (permanent).
	read multiplier: number?, read days: number?, read permanent: boolean?,
}
-- An unused weekly booster: what it is and the Stars paid for it.
export type Token = { id: string, item: string, paid: number }
-- A running weekly booster.
export type Active = { item: string, expires: number }
-- A Stars purchase still being charged or refunded (server/Accounts).
export type Pending = { id: string, item: string, status: "charging" | "refunding" }
-- A line of the account's history: a purchase, a refund, an activation or a reward.
export type Receipt = { at: number, kind: "purchase" | "refund" | "activation" | "reward" | "grant", item: string?, amount: number, currency: Currency }
export type Prefs = { motion: boolean, effects: boolean }
export type Look = { names: string, plates: string, glows: string }
export type Account = {
	starlight: number,
	owned: {[string]: boolean},
	equipped: Look,
	tokens: {Token},
	active: Active?,
	permanent: number, -- 1, 1.5 or 2
	pending: {Pending},
	history: {Receipt},
	prefs: Prefs,
	now: number, -- the datastore's clock when this was read
}

local Shop = {}

Shop.DAY = 86400000
Shop.WEEK = 7 * Shop.DAY
Shop.MAX_HISTORY = 30
Shop.MAX_TOKENS = 64
Shop.SLOTS = table.freeze({ "names", "plates", "glows" } :: {Slot})
Shop.CATEGORIES = table.freeze({ "names", "plates", "glows", "boosters" } :: {Category})
Shop.TITLES = table.freeze({ names = "Names", plates = "Nameplates", glows = "Avatar Glow", boosters = "Boosters" } :: {[string]: string})
Shop.BLURBS = table.freeze({
	names = "Static colours and animated text effects. One name slot.",
	plates = "Decorative backgrounds. Independent of your name colour.",
	glows = "Static avatar outlines, purchased with Starlight.",
	boosters = "More Starlight from playing. The highest multiplier applies.",
} :: {[string]: string})
Shop.DEFAULTS = table.freeze({ names = "name-default", plates = "plate-none", glows = "glow-none" } :: Look)

local list: {Item} = {}
local function add(item: Item) table.insert(list, table.freeze(item)) end
local function slug(name: string): string return (string.gsub(string.lower(name), " ", "-")) end

add({ id = "name-default", category = "names", name = "Default", currency = "starlight", price = 0, animated = false,
	description = "The original lobby name colour." })
for _, row in { {"Yellow", 100}, {"Blue", 750}, {"Cyan", 750}, {"Green", 750}, {"Orange", 750}, {"Red", 750},
	{"Mint", 1000}, {"Pink", 1000}, {"Purple", 1000}, {"Gold", 1500}, {"Rose Quartz", 15000} } do
	add({ id = "name-" .. slug(row[1] :: string), category = "names", name = row[1] :: string, currency = "starlight",
		price = row[2] :: number, animated = false, description = "A permanent, static name colour." })
end
for _, row in { {"Pastel Shift", 150, "pastel"}, {"Rainbow Flow", 250, "rainbow"}, {"Gold Shimmer", 300, "shimmer"},
	{"Galaxy Shift", 350, "galaxy"}, {"Diamond Shine", 400, "diamond"}, {"Prismatic Aurora", 2000, "aurora"} } do
	add({ id = "name-" .. (row[3] :: string), category = "names", name = row[1] :: string, currency = "stars",
		price = row[2] :: number, animated = true, description = "A permanent animated name effect. Changes text only." })
end
add({ id = "plate-none", category = "plates", name = "None", currency = "starlight", price = 0, animated = false,
	description = "Show your name without a decorative plate." })
for _, row in { {"Cloud Puff", 1500, "cloud"}, {"Pink Bubble", 1500, "bubble"}, {"Flower Frame", 2000, "flower"},
	{"Mushroom Banner", 2000, "mushroom"}, {"Leopard Print", 2500, "leopard"}, {"Velvet Eclipse", 2500, "midnight"},
	{"Fairy Garden", 3000, "garden"}, {"Heart Frame", 3500, "hearts"}, {"Royal Ribbon", 4000, "royal"},
	{"Sparkle Bubble", 4000, "sparklebubble"}, {"Enchanted Mushrooms", 4500, "enchanted"}, {"Rainbow Ribbon", 6000, "ribbon"} } do
	add({ id = "plate-" .. (row[3] :: string), category = "plates", name = row[1] :: string, currency = "starlight",
		price = row[2] :: number, animated = false, description = "A permanent static nameplate. Name colour is equipped separately." })
end
for _, row in { {"Celestial", 400, "celestial"}, {"Royal Gold", 450, "royalgold"}, {"Holographic", 500, "holographic"},
	{"Star Glitter", 650, "starglitter"} } do
	add({ id = "plate-" .. (row[3] :: string), category = "plates", name = row[1] :: string, currency = "stars",
		price = row[2] :: number, animated = true, description = "A permanent animated nameplate. Name colour is equipped separately." })
end
add({ id = "glow-none", category = "glows", name = "None", currency = "starlight", price = 0, animated = false,
	description = "No avatar glow." })
for _, row in { {"Soft White", 3000}, {"Cyan", 3500}, {"Green", 3500}, {"Orange", 3500}, {"Pink", 3500},
	{"Purple", 4000}, {"Gold", 5000} } do
	add({ id = "glow-" .. slug(row[1] :: string), category = "glows", name = row[1] :: string, currency = "starlight",
		price = row[2] :: number, animated = false, description = "A permanent static avatar glow. Purely cosmetic." })
end
add({ id = "boost-weekly15", category = "boosters", name = "Weekly Radiance", currency = "stars", price = 800, animated = false,
	multiplier = 1.5, days = 7,
	description = "1.5x total earnings: 150 Starlight for every 100 normally earned. Lasts seven consecutive days after activation." })
add({ id = "boost-weekly2", category = "boosters", name = "Weekly Supernova", currency = "stars", price = 1600, animated = false,
	multiplier = 2, days = 7,
	description = "2x total earnings: 200 Starlight for every 100 normally earned. Lasts seven consecutive days after activation." })
add({ id = "boost-permanent15", category = "boosters", name = "Eternal Radiance", currency = "stars", price = 8000, animated = false,
	multiplier = 1.5, permanent = true,
	description = "1.5x total earnings for good: 150 Starlight for every 100 normally earned." })
add({ id = "boost-permanent2", category = "boosters", name = "Eternal Supernova", currency = "stars", price = 14000, animated = false,
	multiplier = 2, permanent = true,
	description = "2x total earnings for good: 200 Starlight for every 100 normally earned." })

-- What upgrading Eternal Radiance to Eternal Supernova costs.
Shop.UPGRADE = 6000

local byId: {[string]: Item} = {}
for _, item in list do
	assert(not byId[item.id], "Duplicate shop item " .. item.id)
	byId[item.id] = item
end
Shop.items = table.freeze(list)

function Shop.get(id: unknown): Item?
	return if type(id) == "string" then byId[id] else nil
end

-- The cosmetic for [slot] with [id], or nil.
function Shop.cosmetic(slot: Slot, id: unknown): Item?
	local item = Shop.get(id)
	return if item and item.category == slot then item else nil
end

function Shop.isWeekly(item: Item): boolean
	return item.category == "boosters" and not item.permanent
end

function Shop.currencyName(currency: Currency): string
	return if currency == "stars" then "Stars" else "Starlight"
end

-- A brand-new account's look.
function Shop.defaultLook(): Look
	return { names = Shop.DEFAULTS.names, plates = Shop.DEFAULTS.plates, glows = Shop.DEFAULTS.glows }
end

-- The running weekly booster at [now], if it has not run out.
function Shop.active(account: Account, now: number): Active?
	local active = account.active
	return if active and active.expires > now then active else nil
end

-- The multiplier on mini-game Starlight at [now]: the highest of the
-- permanent tier and a running weekly booster.
function Shop.multiplier(account: Account, now: number): number
	local active = Shop.active(account, now)
	local weekly = if active then (Shop.get(active.item) or {} :: any).multiplier or 1 else 1
	return math.max(account.permanent, weekly)
end

function Shop.owned(account: Account, item: Item): boolean
	if item.category == "boosters" then return item.permanent == true and account.permanent >= (item.multiplier or 1) end
	return item.price == 0 or account.owned[item.id] == true
end

-- What [item] costs this account now: Eternal Supernova is an upgrade from Eternal Radiance.
function Shop.cost(account: Account, item: Item): number
	if item.permanent and item.multiplier == 2 and account.permanent == 1.5 then return Shop.UPGRADE end
	return item.price
end

-- The unused weekly tokens buying [item] makes redundant (refunded with it).
function Shop.refunds(account: Account, item: Item): {Token}
	local out: {Token} = {}
	if not item.permanent then return out end
	for _, token in account.tokens do
		local weekly = Shop.get(token.item)
		if weekly and (weekly.multiplier or 1) <= (item.multiplier or 1) then table.insert(out, token) end
	end
	return out
end

function Shop.refundTotal(tokens: {Token}): number
	local total = 0
	for _, token in tokens do total += token.paid end
	return total
end

-- Why this account cannot buy [item] at [now] (nil when it can). [stars] is
-- the Stars balance where it is known (the client's); the server leaves the
-- Stars to the platform.
function Shop.reason(account: Account, item: Item, now: number, stars: number?): string?
	if #account.pending > 0 then return "A purchase is already processing." end
	if Shop.owned(account, item) then return "Already owned." end
	if item.category == "boosters" then
		local multiplier = item.multiplier or 1
		if not item.permanent and account.permanent >= multiplier then
			return "Your permanent booster already gives this bonus or better."
		end
		local active = Shop.active(account, now)
		if item.permanent and active and ((Shop.get(active.item) or {} :: any).multiplier or 1) <= multiplier then
			return "Wait for your active weekly booster to expire before this upgrade."
		end
		if not item.permanent and #account.tokens >= Shop.MAX_TOKENS then return "You have plenty of unused tokens." end
	end
	local cost = Shop.cost(account, item)
	if item.currency == "starlight" and account.starlight < cost then return "Not enough Starlight." end
	if item.currency == "stars" and stars and stars < cost then return "Not enough Stars." end
	return nil
end

-- Why [token] cannot be activated at [now] (nil when it can).
function Shop.activation(account: Account, token: Token, now: number): string?
	if Shop.active(account, now) then return "A weekly booster is already active." end
	local weekly = Shop.get(token.item)
	if not weekly or (weekly.multiplier or 1) <= account.permanent then return "This token would not improve your earnings." end
	return nil
end

-- [items], cheapest first by what they cost this account (currencies mixed),
-- then Starlight before Stars at the same price, then by name.
function Shop.sorted(account: Account, items: {Item}): {Item}
	local out = table.clone(items)
	table.sort(out, function(a: Item, b: Item): boolean
		local x, y = Shop.cost(account, a), Shop.cost(account, b)
		if x ~= y then return x < y end
		if a.currency ~= b.currency then return a.currency == "starlight" end
		return a.name < b.name
	end)
	return out
end

-- The items a tab shows under [filter] (the boosters tab has no filters), sorted.
function Shop.visible(account: Account, category: Category, filter: Filter): {Item}
	local out: {Item} = {}
	for _, item in list do
		if item.category == category and (category == "boosters" or filter == "all"
			or (filter == "owned" and Shop.owned(account, item)) or filter == item.currency) then
			table.insert(out, item)
		end
	end
	return Shop.sorted(account, out)
end

-- A purchase's id from the client's request id: letters, digits, `_` and `-`.
function Shop.request(v: unknown): string?
	if type(v) ~= "string" or #v < 8 or #v > 32 or not string.match(v, "^[%w_%-]+$") then return nil end
	return v
end

-- Admin test tools (server/Accounts): what SHOP_TEST asks for, and the
-- faults the next Stars purchase can be given.
export type Fault = "none" | "refuse" | "unknown" | "deliver"
Shop.TESTS = table.freeze({ grant = true, reward = true, repeat_reward = true, fault = true, expire = true,
	expire_soon = true, reset = true, zero = true } :: {[string]: boolean})

function Shop.fault(v: unknown): Fault?
	return if v == "none" or v == "refuse" or v == "unknown" or v == "deliver" then v :: Fault else nil
end

-- Wire format ------------------------------------------------------------

local MAX_ID = 9007199254740991

local function record(v: unknown): {[unknown]: unknown}?
	return if type(v) == "table" then v :: {[unknown]: unknown} else nil
end

local function whole(v: unknown, high: number?): number?
	if type(v) ~= "number" or v ~= math.floor(v) or v < 0 or v > (high or MAX_ID) then return nil end
	return v
end

local function text(v: unknown): string?
	return if type(v) == "string" and #v > 0 and #v <= 64 then v else nil
end

local function items(v: unknown, limit: number): {unknown}?
	local r = record(v)
	if not r or #r > limit then return nil end
	local out: {unknown} = {}
	for i = 1, #r do out[i] = r[i] end
	return out
end

-- What [look] wears in [slot].
function Shop.slot(look: Look, slot: Slot): string
	return if slot == "names" then look.names elseif slot == "plates" then look.plates else look.glows
end

-- A look as a message payload: three cosmetic ids.
function Shop.lookValue(look: Look): {[string]: types.Value}
	return { names = look.names, plates = look.plates, glows = look.glows }
end

-- A look from [v]: each slot a cosmetic of its own kind, otherwise its default.
function Shop.look(v: unknown): Look
	local r: {[unknown]: unknown} = record(v) or {}
	local names, plates, glows = Shop.cosmetic("names", r.names), Shop.cosmetic("plates", r.plates), Shop.cosmetic("glows", r.glows)
	return { names = if names then names.id else Shop.DEFAULTS.names, plates = if plates then plates.id else Shop.DEFAULTS.plates,
		glows = if glows then glows.id else Shop.DEFAULTS.glows }
end

-- Whether [look] is all defaults.
function Shop.plain(look: Look): boolean
	return look.names == Shop.DEFAULTS.names and look.plates == Shop.DEFAULTS.plates and look.glows == Shop.DEFAULTS.glows
end

function Shop.accountValue(account: Account): {[string]: types.Value}
	local owned: {types.Value} = {}
	for id, yes in account.owned do if yes then table.insert(owned, id) end end
	table.sort(owned :: {any})
	local tokens: {types.Value} = {}
	for i, token in account.tokens do tokens[i] = { id = token.id, item = token.item, paid = token.paid } end
	local pending: {types.Value} = {}
	for i, p in account.pending do pending[i] = { id = p.id, item = p.item, status = p.status } end
	local history: {types.Value} = {}
	for i, h in account.history do
		local row: {[string]: types.Value} = { at = h.at, kind = h.kind, amount = h.amount, currency = h.currency }
		if h.item then row.item = h.item end
		history[i] = row
	end
	local out: {[string]: types.Value} = {
		starlight = account.starlight, owned = value.array(owned), equipped = Shop.lookValue(account.equipped),
		tokens = value.array(tokens), permanent = math.round(account.permanent * 10), pending = value.array(pending),
		history = value.array(history), motion = account.prefs.motion, effects = account.prefs.effects, now = account.now,
	}
	if account.active then out.active = { item = account.active.item, expires = account.active.expires } end
	return out
end

local KINDS: {[string]: boolean} = { purchase = true, refund = true, activation = true, reward = true, grant = true }

-- An account from the server; nil for anything malformed.
function Shop.account(v: unknown): Account?
	local r = record(v)
	if not r then return nil end
	local starlight, now, tier = whole(r.starlight), whole(r.now), whole(r.permanent, 20)
	local permanent = if tier == 10 then 1 elseif tier == 15 then 1.5 elseif tier == 20 then 2 else nil
	if not starlight or not now or not permanent or type(r.motion) ~= "boolean" or type(r.effects) ~= "boolean" then return nil end
	local ownedList, tokenList = items(r.owned, #list), items(r.tokens, Shop.MAX_TOKENS)
	local pendingList, historyList = items(r.pending, 16), items(r.history, Shop.MAX_HISTORY)
	if not ownedList or not tokenList or not pendingList or not historyList then return nil end
	local owned: {[string]: boolean} = {}
	for _, id in ownedList do
		local item = Shop.get(id)
		if item then owned[item.id] = true end
	end
	local tokens: {Token} = {}
	for _, t in tokenList do
		local tr = record(t)
		local id, item, paid = if tr then text(tr.id) else nil, if tr then Shop.get(tr.item) else nil, if tr then whole(tr.paid) else nil
		if not id or not item or not Shop.isWeekly(item) or not paid then return nil end
		table.insert(tokens, { id = id, item = item.id, paid = paid })
	end
	local pending: {Pending} = {}
	for _, p in pendingList do
		local pr = record(p)
		local id, item = if pr then text(pr.id) else nil, if pr then Shop.get(pr.item) else nil
		local status = if pr then pr.status else nil
		if not id or not item or (status ~= "charging" and status ~= "refunding") then return nil end
		table.insert(pending, { id = id, item = item.id, status = status :: any })
	end
	local history: {Receipt} = {}
	for _, h in historyList do
		local hr = record(h)
		if not hr then return nil end
		local at, amount, kind, currency = whole(hr.at), whole(hr.amount), hr.kind, hr.currency
		local item = if hr.item == nil then nil else Shop.get(hr.item)
		if not at or not amount or type(kind) ~= "string" or not KINDS[kind] or (currency ~= "starlight" and currency ~= "stars")
			or (hr.item ~= nil and not item) then return nil end
		table.insert(history, { at = at, kind = kind :: any, item = if item then item.id else nil, amount = amount, currency = currency :: Currency })
	end
	local active: Active? = nil
	if r.active ~= nil then
		local ar = record(r.active)
		local item, expires = if ar then Shop.get(ar.item) else nil, if ar then whole(ar.expires) else nil
		if not item or not Shop.isWeekly(item) or not expires then return nil end
		active = { item = item.id, expires = expires }
	end
	return { starlight = starlight, owned = owned, equipped = Shop.look(r.equipped), tokens = tokens, active = active,
		permanent = permanent, pending = pending, history = history, prefs = { motion = r.motion :: boolean, effects = r.effects :: boolean },
		now = now }
end

return table.freeze(Shop)
