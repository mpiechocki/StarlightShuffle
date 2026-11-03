--!strict
-- The wire protocol's validators (shared/Net) and the mini-game registry
-- (shared/Games): what clients and servers accept from each other.
local test = require("@moonbase/test")
local Net = require("@project/shared/Net")
local Games = require("@project/shared/Games")

test.unit("rounds survive the wire and bad ones are refused", function(t)
	local round = Net.round(Net.roundValue({ phase = "playing", game = "lucky_shot", round = 3, remaining = 12.345 }))
	t:truthy(round ~= nil)
	if round then
		t:equal(round.phase, "playing")
		t:equal(round.game, "lucky_shot")
		t:equal(round.round, 3)
		t:equal(round.remaining, 12.35)
	end
	t:equal(Net.round({ phase = "dancing", round = 1, remaining = 1 }), nil)
	t:equal(Net.round({ phase = "intro", round = 1.5, remaining = 1 }), nil)
	t:equal(Net.round({ phase = "intro", round = 1, remaining = -1 }), nil)
	t:equal(Net.round("intro"), nil)
	t:equal(Net.round({ phase = "waiting", round = 0, remaining = 0, players = -1 }), nil)
end)

test.unit("a break between mini-games names the one coming", function(t)
	local round = Net.round(Net.roundValue({ phase = "break", game = "blast_mining", round = 2, remaining = Games.BREAK, players = 2 }))
	t:truthy(round ~= nil)
	if round then
		t:equal(round.players, 2)
		t:equal(round.phase, "break")
		t:equal(round.game, "blast_mining")
		t:equal(round.remaining, Games.BREAK)
	end
	t:equal(Games.BREAK, 20)
end)

test.unit("leaderboards survive the wire and bad rows are refused", function(t)
	local board = Net.board(Net.boardValue({ top = { { player = 7, name = "Ada", starlights = 12 } }, rank = 1, mine = 12 }))
	t:truthy(board ~= nil)
	if board then
		t:equal(#board.top, 1)
		t:equal(board.top[1].name, "Ada")
		t:equal(board.rank, 1)
	end
	-- An empty board, and nobody ranked yet.
	local empty = Net.board(Net.boardValue({ top = {}, rank = nil, mine = 0 }))
	t:truthy(empty ~= nil and #empty.top == 0 and empty.rank == nil)
	t:equal(Net.board({ top = { { player = 7, name = "", starlights = 1 } }, mine = 0 }), nil)
	t:equal(Net.board({ top = { { player = 7, name = "Ada", starlights = -1 } }, mine = 0 }), nil)
end)

test.unit("names are clipped on a character boundary", function(t)
	local long = string.rep("é", 40) -- 80 bytes
	local clipped = Net.clip(long)
	t:truthy(#clipped <= Net.MAX_NAME)
	t:truthy(utf8.len(clipped) ~= nil)
	t:equal(Net.name({ alias = "Ada" }, 1), "Ada")
	t:equal(Net.name(nil, 42), "Player 42")
end)

test.unit("identities round-trip", function(t)
	local packed = Net.identity({ session = 5, player = 9, name = "Ada", outfit = { 241120, -2 }, avatar = "abc.png" })
	local identity = Net.readIdentity(packed)
	t:truthy(identity ~= nil)
	if identity then
		t:equal(identity.name, "Ada")
		t:equal(identity.outfit and identity.outfit[2], -2)
		t:equal(identity.avatar, "abc.png")
	end
end)

test.unit("the cycle loops through every mini-game", function(t)
	local count = #Games.list
	t:truthy(count >= 1)
	local seen: {[string]: boolean} = {}
	local index = 0
	for _ = 1, count do
		local game, nextIndex = Games.after(index)
		seen[game.id], index = true, nextIndex
		t:equal(game.scene, "scene:" .. game.id)
		t:truthy(game.duration > 0)
	end
	for _, game in Games.list do t:truthy(seen[game.id], game.id .. " is played") end
	-- And comes back round to the first.
	local first = Games.after(index)
	t:equal(first.id, Games.list[1].id)
end)
