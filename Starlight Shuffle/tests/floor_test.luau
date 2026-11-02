--!strict
-- The walk-area floor (shared/Floor) without a navmesh: avatars stay inside the
-- rectangle and are moved out of the furniture's walk blocks the shortest way.
local test = require("@moonbase/test")
local Floor = require("@project/shared/Floor")

local function floor()
	return Floor.rectangle(vector.create(0, 0, 0), 10, 6, {
		{ minX = 1, maxX = 3, minZ = -1, maxZ = 1 }, -- a sofa
	})
end

test.unit("the rectangle bounds where avatars stand", function(t)
	local f = floor()
	local p = assert(f:moveAlongSurface(vector.create(0, 0, 0), vector.create(9, 2, -9)))
	t:equal(p.x, 5); t:equal(p.y, 0); t:equal(p.z, -3)
	local q = assert(f:nearestPoint(vector.create(-1, 0, 2)))
	t:equal(q.x, -1); t:equal(q.z, 2)
end)

test.unit("a walk block pushes avatars out by the shortest way", function(t)
	local f = floor()
	local p = assert(f:moveAlongSurface(vector.create(0, 0, 0), vector.create(1.3, 0, 0.2)))
	t:equal(p.x, 1) -- nearest the block's left side
	t:truthy(math.abs(p.z - 0.2) < 1e-6) -- vectors are single precision
	local q = assert(f:moveAlongSurface(vector.create(0, 0, 0), vector.create(2, 0, 0.9)))
	t:equal(q.x, 2); t:equal(q.z, 1) -- nearest its front
	for _ = 1, 50 do
		local r = assert(f:randomPoint())
		t:truthy(not (r.x > 1 and r.x < 3 and r.z > -1 and r.z < 1), "random spots avoid the block")
	end
end)
