--!strict
-- Where Star Pass's survivors stand, for any number of them. Positions are
-- percentages of the crowd area (the view above the bottom controls): x of
-- the avatar's centre, `bottom` of its feet from the area's bottom, its box
-- `width` and `height`, and `depth` (higher in front). One survivor stands
-- large in the foreground (the local player while alive, else the first
-- survivor in seat order); everyone else stands in staggered rows behind,
-- larger figures overlapping on purpose. With one to three others they spread
-- widely instead of filling a grid. Positions depend only on the count and
-- each one's place in seat order, so nothing moves until someone is out.
local Crowd = {}

export type Spot = { x: number, bottom: number, width: number, height: number, depth: number }

local FRONT: Spot = { x = 50, bottom = 0, width = 39, height = 56, depth = 100 }
Crowd.FRONT = FRONT

local FEW: {{number}} = { { 24 }, { 20, 80 }, { 12, 50, 88 } }

-- Spots for [count] survivors behind the foreground one, in their seat order.
function Crowd.layout(count: number): {Spot}
	local columns = if count <= 3 then 3 elseif count > 24 then 6 elseif count > 16 then 5 else 4
	local rows = math.ceil(count / columns)
	local height = if count > 24 then 30 elseif count > 16 then 34 else 38
	local width = math.min(28, 104 / columns)
	local spots: {Spot} = {}
	for i = 1, count do
		local row, col = (i - 1) // columns, (i - 1) % columns
		local inRow = math.min(columns, count - row * columns)
		local x: number, bottom: number
		if count <= 3 then
			x, bottom = FEW[count][i], 22
		else
			x = 50 + (col - (inRow - 1) / 2) * (90 / columns) + (if row % 2 == 1 then 2 else -2)
			-- Rows step back up the area, no further than keeps the back row's heads inside it.
			local step = math.min(17, (100 - height - 19) / math.max(1, rows - 1))
			bottom = 19 + (rows - 1 - row) * step
		end
		spots[i] = { x = x, bottom = bottom, width = width, height = height, depth = 10 + row }
	end
	return spots
end

return table.freeze(Crowd)
