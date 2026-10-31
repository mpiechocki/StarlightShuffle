--!strict
-- The mini-games' shared tie policy and podium prizes. Standings sort by
-- points (highest first; scores may be negative), then by who reached their
-- final score earliest on the server's clock, then by player id, so every
-- client and the server agree. The top three places take PRIZES Starlights.
local Standings = {}

export type Score = { player: number, name: string, score: number, reachedAt: number }

Standings.PLACES = 3
Standings.PRIZES = table.freeze({ 5, 3, 2 })

function Standings.rank(scores: {Score}): {Score}
	local out = table.clone(scores)
	table.sort(out, function(a: Score, b: Score): boolean
		if a.score ~= b.score then return a.score > b.score end
		if a.reachedAt ~= b.reachedAt then return a.reachedAt < b.reachedAt end
		return a.player < b.player
	end)
	return out
end

-- Starlights for [place] (1-based); 0 off the podium.
function Standings.prize(place: number): number
	return Standings.PRIZES[place] or 0
end

return table.freeze(Standings)
