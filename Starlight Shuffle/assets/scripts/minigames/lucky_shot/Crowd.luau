--!strict
-- Where everyone stands in the meadow, for any roster size: the local player
-- large and in front at the centre; everyone else in staggered rows behind,
-- each row smaller and higher. Positions are percentages of the game surface
-- (x of the avatar's centre, bottom of its feet, its box width and height),
-- and depend only on how many play and each one's place in seat order, so
-- nobody moves when scores change. A rear avatar mostly hidden by one in a
-- nearer row is drawn a little see-through (local readability only).
-- Watchers (no seat of their own) see every competitor in the rows.
local Crowd = {}

export type Spot = { x: number, bottom: number, width: number, height: number, row: number, depth: number, opacity: number }

local FRONT_FOUR = { 7, 28, 72, 93 }
local FRONT_SIX = { 6, 22, 38, 62, 78, 94 }

-- The spot of the local player.
local LOCAL: Spot = { x = 50, bottom = 4, width = 34, height = 30, row = -1, depth = 100, opacity = 1 }
Crowd.LOCAL = LOCAL

-- Spots for [count] other players, in their seat order.
function Crowd.layout(count: number): {Spot}
	local columns = if count <= 2 then 2 elseif count > 24 then 8 else 5
	local front = if count <= 2 then 2 elseif count > 24 then 6 else 4
	local rows = 1 + math.ceil(math.max(0, count - front) / columns)
	local spots: {Spot} = {}
	for i = 1, count do
		local j = i - 1
		local row = if j < front then 0 else 1 + (j - front) // columns
		local col = if j < front then j else (j - front) % columns
		local ratio = if rows == 1 then 0 else row / (rows - 1)
		local inRow = if row == 0 then math.min(front, count) else math.min(columns, count - front - (row - 1) * columns)
		local x: number
		if columns == 2 then
			x = if col == 0 then 10 else 90
		elseif row == 0 then
			x = if front == 6 then FRONT_SIX[col + 1] else FRONT_FOUR[col + 1]
		else
			x = 50 - (inRow - 1) * 43 / (columns - 1) + col * 86 / (columns - 1)
		end
		spots[i] = { x = x, bottom = 9 + ratio * 17, height = 23 - ratio * 9,
			width = if columns == 8 then 15 else 24 - ratio * 6, row = row, depth = 20 - row, opacity = 1 }
	end
	-- See-through only where a nearer row covers much of this one.
	for _, b in spots do
		for _, c in spots do
			if c.row < b.row and math.abs(c.x - b.x) < (c.width + b.width) * 0.35
				and math.abs((c.bottom + c.height / 2) - (b.bottom + b.height / 2)) < (c.height + b.height) * 0.4 then
				b.opacity = if b.row > 1 then 0.76 else 0.86
				break
			end
		end
	end
	return spots
end

return table.freeze(Crowd)
