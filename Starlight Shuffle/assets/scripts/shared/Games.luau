--!strict
-- The mini-games a cycle plays, in order, looping back to the first. Each one
-- is its own scene (`scenes/<scene>.json`) and its own folder under
-- `minigames/<id>/`: `Server.luau` runs its rules on the cycle's server and
-- `Client.luau` its HUD and effects. server/Games and client/Games list those
-- modules by id. To add a mini-game, add its scene and folder, then a row here
-- and a line in each of those registries (see the README).
export type Game = {
	read id: string, -- also the folder under minigames/
	read title: string,
	read blurb: string, -- one line shown while it is about to start
	read scene: string, -- the scene's asset reference, "scene:<name>"
	read duration: number, -- seconds of play
	read intro: number?, -- seconds it is announced before play (Games.INTRO when nil)
}

local list: {Game} = {
	{ id = "head_to_head", title = "Head to Head", blurb = "Match your canvas to the reference, head by head.",
		scene = "scene:head_to_head", duration = 90, intro = 10 },
	{ id = "blast_mining", title = "Blast Mining", blurb = "Swing as each rock lands. Mind the bombs!",
		scene = "scene:blast_mining", duration = 60, intro = 4 },
	{ id = "lucky_shot", title = "Lucky Shot", blurb = "Tap clouds to fire your slingshot. Avoid storm clouds.",
		scene = "scene:lucky_shot", duration = 45, intro = 10 },
	{ id = "minigame_1", title = "Mini-game 1", blurb = "A blank mini-game. Walk around!", scene = "scene:minigame_1", duration = 30 },
	{ id = "minigame_2", title = "Mini-game 2", blurb = "A blank mini-game. Walk around!", scene = "scene:minigame_2", duration = 30 },
	{ id = "minigame_3", title = "Mini-game 3", blurb = "A blank mini-game. Walk around!", scene = "scene:minigame_3", duration = 30 },
}

local byId: {[string]: Game} = {}
for _, game in list do
	assert(not byId[game.id], "Duplicate mini-game id " .. game.id)
	byId[game.id] = table.freeze(game)
end

return table.freeze({
	INTRO = 5,
	list = table.freeze(list),
	-- The mini-game with [id], or nil.
	get = function(id: string?): Game?
		return if id then byId[id] else nil
	end,
	-- The mini-game after the one at [index] (1-based), looping; and its index.
	after = function(index: number): (Game, number)
		local nextIndex = index % #list + 1
		return list[nextIndex], nextIndex
	end,
})
