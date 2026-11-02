--!strict
-- The admins' mini-game lineup: which games a cycle picks (shared/Games), the
-- admin list from the startup settings (server/Admins)
-- and the lineup message (shared/Net).
local test = require("@moonbase/test")
local Games = require("@project/shared/Games")
local Net = require("@project/shared/Net")
local Admins = require("@project/server/Admins")

local function indexOf(id: string): number
	for i, game in Games.list do if game.id == id then return i end end
	error("no game " .. id)
end

test.unit("included keeps known ids in cycle order and means everything when empty", function(t)
	local all = Games.included(nil)
	t:equal(#all, #Games.list)
	t:equal(#Games.included({}), #Games.list)
	t:equal(#Games.included({ "nope" }), #Games.list)
	local some = Games.included({ "pillow_fight", "nope", "head_to_head" })
	t:equal(#some, 2)
	t:equal(some[1], "head_to_head") -- list order, not the order given
	t:equal(some[2], "pillow_fight")
end)

test.unit("a cycle picks only included games, looping, in list order", function(t)
	local only = { "lucky_shot", "pillow_fight" }
	local game, at = Games.pick(0, only, 4)
	t:equal(game.id, "lucky_shot")
	game, at = Games.pick(at, only, 4)
	t:equal(game.id, "pillow_fight")
	game, at = Games.pick(at, only, 4)
	t:equal(game.id, "lucky_shot") -- loops past the left-out ones
	-- One game alone plays again and again.
	game = Games.pick(indexOf("blast_mining"), { "blast_mining" }, 1)
	t:equal(game.id, "blast_mining")
	-- Everything included is the plain cycle order.
	game = Games.pick(0, Games.included(nil), 4)
	t:equal(game.id, Games.list[1].id)
end)

test.unit("too few players skip a game unless an admin left only such games", function(t)
	local game = Games.pick(indexOf("lucky_shot"), { "star_pass", "pillow_fight" }, 1)
	t:equal(game.id, "pillow_fight") -- Star Pass needs two
	game = Games.pick(indexOf("lucky_shot"), { "star_pass", "pillow_fight" }, 2)
	t:equal(game.id, "star_pass")
	game = Games.pick(0, { "star_pass" }, 1)
	t:equal(game.id, "star_pass") -- the admin asked for it
end)

test.unit("admins are the whole account ids in the startup settings", function(t)
	local ids = Admins.ids({ admins = { 12, 34.5, "56", -1, 78 } })
	t:truthy(ids[12])
	t:truthy(ids[78])
	t:equal(ids[34.5], nil)
	t:equal(ids[56], nil)
	t:equal(ids[-1], nil)
	t:equal(next(Admins.ids(nil)), nil)
	t:equal(next(Admins.ids({ admins = "12" })), nil)
	local admins = Admins.new({ admins = { 7 } })
	t:truthy(admins.is({ session_id = 1, player_id = 7, isActive = true } :: any))
	t:truthy(not admins.is({ session_id = 2, player_id = 8, isActive = true } :: any))
end)

test.unit("the lineup message is validated", function(t)
	local lineup = assert(Net.lineup(Net.lineupValue({ included = { "lucky_shot" }, current = "lucky_shot", upNext = "lucky_shot" })))
	t:equal(lineup.included[1], "lucky_shot")
	t:equal(lineup.upNext, "lucky_shot")
	t:equal(Net.lineup({ included = {} }), nil) -- never empty
	t:equal(Net.lineup({ included = { "a", "a" } }), nil) -- no repeats
	t:equal(Net.lineup({ included = { 5 } }), nil)
	t:equal(Net.gameIds({ "a", "b" }, 1), nil) -- too many
end)
