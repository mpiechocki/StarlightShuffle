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
	read minPlayers: number?, -- skipped in rounds with fewer players than this (never fewer than MIN_PLAYERS)
}

local list: {Game} = {
	{ id = "head_to_head", title = "Head to Head", blurb = "Match your canvas to the reference, head by head.",
		scene = "scene:head_to_head", duration = 90, intro = 10 },
	{ id = "blast_mining", title = "Blast Mining", blurb = "Swing as each rock lands. Mind the bombs!",
		scene = "scene:blast_mining", duration = 60, intro = 4 },
	{ id = "lucky_shot", title = "Lucky Shot", blurb = "Tap clouds to fire your slingshot. Avoid storm clouds.",
		scene = "scene:lucky_shot", duration = 45, intro = 10 },
	{ id = "star_pass", title = "Star Pass", blurb = "Charge your star and pass it on before it bursts!",
		scene = "scene:star_pass", duration = 300, intro = 10 },
	-- Reveal, countdown and 60 s of play (it ends itself sooner with one room).
	{ id = "pillow_fight", title = "Pillow Fight", blurb = "Aim, hold and throw. Red ! means dodge.",
		scene = "scene:pillow_fight", duration = 67, intro = 15 },
	{ id = "starcatchers", title = "Starcatchers", blurb = "Throw your net, catch stars, dodge satellites.",
		scene = "scene:starcatchers", duration = 60, intro = 8 },
}

local MIN_PLAYERS = 3

local byId: {[string]: Game} = {}
for _, game in list do
	assert(not byId[game.id], "Duplicate mini-game id " .. game.id)
	byId[game.id] = table.freeze(game)
end

return table.freeze({
	INTRO = 5,
	-- Seconds a cycle spends back in the lobby scene between mini-games.
	BREAK = 20,
	-- No mini-game starts with fewer players than this: a cycle waits for them
	-- in the lobby scene.
	MIN_PLAYERS = MIN_PLAYERS,
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
	-- The ids of [ids] that are mini-games, in list order; every id when none is.
	-- (The admins' lineup: which mini-games cycles play.)
	included = function(ids: {string}?): {string}
		local wanted: {[string]: boolean} = {}
		for _, id in ids or {} do wanted[id] = true end
		local out: {string} = {}
		for _, game in list do
			if wanted[game.id] then table.insert(out, game.id) end
		end
		if #out == 0 then
			for _, game in list do table.insert(out, game.id) end
		end
		return out
	end,
	-- What a cycle plays after the mini-game at [index] (0 before the first):
	-- the next included one that [players] can play, looping; when no included
	-- one takes that few players, the next included one anyway (an admin chose
	-- it); and its index.
	pick = function(index: number, included: {string}, players: number): (Game, number)
		local allowed: {[string]: boolean} = {}
		for _, id in included do allowed[id] = true end
		local fallback: number? = nil
		for step = 1, #list do
			local at = (index + step - 1) % #list + 1
			local game = list[at]
			if allowed[game.id] then
				if math.max(MIN_PLAYERS, game.minPlayers or 1) <= players then return game, at end
				fallback = fallback or at
			end
		end
		local at = fallback or (index % #list + 1)
		return list[at], at
	end,
})
