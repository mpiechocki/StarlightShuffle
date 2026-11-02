--!strict
-- What a mini-game pays in Starlight. Everyone who takes part and is still
-- there when play ends earns COMPLETE (an active player: they did something in
-- it), and the top three places add PLACES (one placement bonus each). The
-- cycle boosts a player's whole take for a mini-game once, by their highest
-- active booster (shared/Shop), when it is awarded.
local Rewards = {}

Rewards.COMPLETE = 50
Rewards.PLACES = table.freeze({ 50, 30, 15 })

-- The placement bonus for [place] (1-based); 0 off the podium.
function Rewards.place(place: number): number
	return Rewards.PLACES[place] or 0
end

-- [base] Starlight with a [multiplier] booster: floor(base x multiplier).
function Rewards.boosted(base: number, multiplier: number): number
	return math.floor(base * multiplier + 1e-9)
end

return table.freeze(Rewards)
