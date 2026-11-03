--!strict
-- What a mini-game pays in Starlight: only its top three places, PLACES
-- (the same in every mini-game); everyone else earns nothing. The cycle
-- boosts a player's take for a mini-game once, by their highest active
-- booster (shared/Shop), when it is awarded.
local Rewards = {}

Rewards.PLACES = table.freeze({ 50, 25, 10 })

-- The placement bonus for [place] (1-based); 0 off the podium.
function Rewards.place(place: number): number
	return Rewards.PLACES[place] or 0
end

-- [base] Starlight with a [multiplier] booster: floor(base x multiplier).
function Rewards.boosted(base: number, multiplier: number): number
	return math.floor(base * multiplier + 1e-9)
end

return table.freeze(Rewards)
