--!strict
-- The lobby shop's catalogue and rules (shared/Shop), its wire formats, the
-- looks on avatar identities (shared/Net) and the mini-game rewards
-- (shared/Rewards).
local test = require("@moonbase/test")
local Shop = require("@project/shared/Shop")
local Net = require("@project/shared/Net")
local Rewards = require("@project/shared/Rewards")

local NOW = 1_700_000_000_000

local function account(overrides: {[string]: any}?): Shop.Account
	local out: Shop.Account = { starlight = 0, owned = {}, equipped = Shop.defaultLook(), tokens = {}, active = nil,
		permanent = 1, pending = {}, history = {}, prefs = { motion = false, effects = false }, now = NOW }
	for key, v in overrides or {} do (out :: any)[key] = v end
	return out
end

local function ids(items: {Shop.Item}): {string}
	local out: {string} = {}
	for i, item in items do out[i] = item.id end
	return out
end

test.unit("every animated cosmetic costs Stars and every Starlight cosmetic is static", function(t)
	local cosmetics = 0
	for _, item in Shop.items do
		if item.category ~= "boosters" and item.price > 0 then
			cosmetics += 1
			t:equal(item.animated, item.currency == "stars")
		end
		if item.category == "glows" then t:equal(item.currency, "starlight") end
		if item.category == "boosters" then t:equal(item.currency, "stars") end
	end
	t:equal(cosmetics, 17 + 16 + 7)
end)

test.unit("items sort by price across currencies, Starlight first at a tie, then by name", function(t)
	local names = ids(Shop.visible(account(), "names", "all"))
	t:equal(names[1], "name-default")
	t:equal(names[2], "name-yellow") -- 100 Starlight
	t:equal(names[3], "name-pastel") -- 150 Stars
	t:equal(names[4], "name-rainbow") -- 250 Stars
	t:equal(names[8], "name-blue") -- the first of the 750 Starlight, by name
	t:equal(names[#names], "name-rose-quartz")
	local plates = ids(Shop.visible(account(), "plates", "all"))
	t:equal(plates[1], "plate-none")
	t:equal(plates[2], "plate-celestial") -- 400 Stars before 1,500 Starlight
	t:equal(plates[6], "plate-cloud") -- Cloud Puff and Pink Bubble tie at 1,500: by name
	t:equal(plates[7], "plate-bubble")
	-- Filters keep the order.
	local stars = ids(Shop.visible(account(), "names", "stars"))
	t:equal(stars[1], "name-pastel")
	t:equal(stars[#stars], "name-aurora")
	local owned = ids(Shop.visible(account({ owned = { ["name-gold"] = true } }), "names", "owned"))
	t:equal(#owned, 2); t:equal(owned[1], "name-default"); t:equal(owned[2], "name-gold")
	-- Boosters have no filters: all four, the upgrade price where it applies.
	t:equal(#Shop.visible(account(), "boosters", "owned"), 4)
	local upgraded = ids(Shop.visible(account({ permanent = 1.5 }), "boosters", "all"))
	t:equal(upgraded[1], "boost-weekly15")
	t:equal(upgraded[3], "boost-permanent2") -- 6,000 Stars as an upgrade
	t:equal(upgraded[4], "boost-permanent15")
end)

test.unit("purchases are blocked when owned, unaffordable, pending or redundant", function(t)
	local yellow = assert(Shop.get("name-yellow"))
	t:equal(Shop.reason(account({ starlight = 99 }), yellow, NOW), "Not enough Starlight.")
	t:equal(Shop.reason(account({ starlight = 100 }), yellow, NOW), nil)
	t:equal(Shop.reason(account({ starlight = 500, owned = { ["name-yellow"] = true } }), yellow, NOW), "Already owned.")
	t:equal(Shop.reason(account({ starlight = 500, pending = { { id = "s1_x", item = "name-rainbow", status = "charging" } } }), yellow, NOW),
		"A purchase is already processing.")
	local rainbow = assert(Shop.get("name-rainbow"))
	t:equal(Shop.reason(account(), rainbow, NOW, 249), "Not enough Stars.")
	t:equal(Shop.reason(account(), rainbow, NOW, nil), nil) -- the server leaves Stars to the platform
	local weekly15, weekly2 = assert(Shop.get("boost-weekly15")), assert(Shop.get("boost-weekly2"))
	local eternal15, eternal2 = assert(Shop.get("boost-permanent15")), assert(Shop.get("boost-permanent2"))
	-- Permanent 2x makes every weekly booster redundant; 1.5x only the 1.5x one.
	t:truthy(Shop.reason(account({ permanent = 2 }), weekly2, NOW) ~= nil)
	t:truthy(Shop.reason(account({ permanent = 1.5 }), weekly15, NOW) ~= nil)
	t:equal(Shop.reason(account({ permanent = 1.5 }), weekly2, NOW), nil)
	-- Lower tiers and duplicates of permanent boosters count as owned.
	t:equal(Shop.reason(account({ permanent = 2 }), eternal15, NOW), "Already owned.")
	t:equal(Shop.cost(account({ permanent = 1.5 }), eternal2), Shop.UPGRADE)
	t:equal(Shop.cost(account(), eternal2), 14000)
	-- An upgrade that would make the running weekly booster redundant waits for it.
	local running = account({ active = { item = "boost-weekly15", expires = NOW + Shop.DAY } })
	t:equal(Shop.reason(running, eternal15, NOW), "Wait for your active weekly booster to expire before this upgrade.")
	t:equal(Shop.reason(running, eternal15, NOW + 2 * Shop.DAY), nil)
	t:equal(Shop.reason(account({ active = { item = "boost-weekly2", expires = NOW + Shop.DAY } }), eternal15, NOW), nil)
end)

test.unit("the highest active multiplier applies, and tokens activate only when they improve it", function(t)
	t:equal(Shop.multiplier(account(), NOW), 1)
	t:equal(Shop.multiplier(account({ permanent = 1.5, active = { item = "boost-weekly2", expires = NOW + 10 } }), NOW), 2)
	-- When the weekly 2x expires, the permanent 1.5x resumes.
	t:equal(Shop.multiplier(account({ permanent = 1.5, active = { item = "boost-weekly2", expires = NOW + 10 } }), NOW + 10), 1.5)
	local token = { id = "t1", item = "boost-weekly15", paid = 800 }
	t:equal(Shop.activation(account({ tokens = { token } }), token, NOW), nil)
	t:truthy(Shop.activation(account({ tokens = { token }, permanent = 1.5 }), token, NOW) ~= nil)
	t:equal(Shop.activation(account({ tokens = { token }, active = { item = "boost-weekly2", expires = NOW + 5 } }), token, NOW),
		"A weekly booster is already active.")
	-- A permanent purchase refunds the tokens it makes redundant, at what they cost.
	local tokens = { { id = "a", item = "boost-weekly15", paid = 800 }, { id = "b", item = "boost-weekly2", paid = 1600 } }
	t:equal(Shop.refundTotal(Shop.refunds(account({ tokens = tokens }), assert(Shop.get("boost-permanent15")))), 800)
	t:equal(Shop.refundTotal(Shop.refunds(account({ tokens = tokens }), assert(Shop.get("boost-permanent2")))), 2400)
	t:equal(#Shop.refunds(account({ tokens = tokens }), assert(Shop.get("boost-weekly2"))), 0)
end)

test.unit("rewards are boosted once per round, rounded down", function(t)
	t:equal(Rewards.place(1), 50); t:equal(Rewards.place(2), 25); t:equal(Rewards.place(3), 10)
	t:equal(Rewards.boosted(Rewards.place(1), 1.5), 75)
	t:equal(Rewards.boosted(Rewards.place(1), 2), 100)
	t:equal(Rewards.boosted(Rewards.place(2), 1.5), 37)
	t:equal(Rewards.place(4), 0)
end)

test.unit("accounts cross the wire whole and malformed ones are refused", function(t)
	local sent = account({ starlight = 1234, owned = { ["name-gold"] = true, ["plate-cloud"] = true },
		equipped = { names = "name-gold", plates = "plate-cloud", glows = "glow-none" },
		tokens = { { id = "s1_r1", item = "boost-weekly2", paid = 1600 } }, permanent = 1.5,
		active = { item = "boost-weekly15", expires = NOW + 1000 },
		history = { { at = NOW, kind = "purchase", item = "name-gold", amount = 1500, currency = "starlight" } },
		prefs = { motion = true, effects = false } })
	local got = assert(Shop.account(Shop.accountValue(sent)))
	t:equal(got.starlight, 1234); t:equal(got.permanent, 1.5)
	t:equal(got.owned["name-gold"], true); t:equal(got.equipped.plates, "plate-cloud")
	t:equal(got.tokens[1].paid, 1600); t:equal((got.active :: Shop.Active).item, "boost-weekly15")
	t:equal(got.history[1].amount, 1500); t:equal(got.prefs.motion, true)
	local broken = Shop.accountValue(sent)
	broken.starlight = -5
	t:equal(Shop.account(broken), nil)
	t:equal(Shop.account("nope"), nil)
	-- A look's unknown or misplaced ids are the defaults.
	local look = Shop.look({ names = "plate-cloud", plates = "plate-holographic", glows = "glow-made-up" })
	t:equal(look.names, "name-default"); t:equal(look.plates, "plate-holographic"); t:equal(look.glows, "glow-none")
	t:equal(Shop.request("short"), nil)
	t:equal(Shop.request("r1a2b3c4d"), "r1a2b3c4d")
	t:equal(Shop.request("has space in it"), nil)
end)

test.unit("an avatar's identity carries its look", function(t)
	local plain = assert(Net.readIdentity(Net.identity({ session = 3, player = 9, name = "Ann" })))
	t:equal(plain.look, nil)
	local styled = assert(Net.readIdentity(Net.identity({ session = 3, player = 9, name = "Ann", avatar = "abc.png",
		look = { names = "name-rainbow", plates = "plate-celestial", glows = "glow-gold" } })))
	local look = assert(styled.look)
	t:equal(look.names, "name-rainbow"); t:equal(look.plates, "plate-celestial"); t:equal(look.glows, "glow-gold")
	t:equal(styled.avatar, "abc.png")
	-- Trailing bytes that are not a look are refused.
	local bytes = Net.identity({ session = 3, player = 9, name = "Ann" })
	local longer = buffer.create(buffer.len(bytes) + 1)
	buffer.copy(longer, 0, bytes, 0)
	t:equal(Net.readIdentity(longer), nil)
end)

test.unit("admin test tools: known actions and faults only", function(t)
	t:equal(Shop.TESTS.grant, true); t:equal(Shop.TESTS.reset, true)
	t:equal(Shop.TESTS.give_me_stars, nil)
	t:equal(Shop.fault("unknown"), "unknown"); t:equal(Shop.fault("none"), "none")
	t:equal(Shop.fault("explode"), nil); t:equal(Shop.fault(3), nil)
	-- A grant shows in the history as one.
	local sent = account({ history = { { at = NOW, kind = "grant", amount = 1000, currency = "starlight" } } })
	t:equal((assert(Shop.account(Shop.accountValue(sent)))).history[1].kind, "grant")
end)
