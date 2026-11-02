--!strict
-- Where avatars may walk in a native scene: its baked navmesh when it has one,
-- else the rectangle its `walk-area` entity marks (gameplay/WalkArea), so a new
-- scene is playable before anyone bakes it. The rectangle has no obstacles:
-- avatars slide along its edges and walk through props on it. The server and
-- every client read the same floor, so movement checks agree. Furniture on a
-- rectangle can be walked around: `walk-block-1`, `walk-block-2`, … entities
-- (gameplay/WalkBlock) each keep avatars out of their own smaller rectangle.
local scenes = require("@moonbase/scene")
local Movement = require("@moonbase/movement")

local AREA = "walk-area" -- the entity, and its WalkArea component's id
local BLOCK = "walk-block-" -- numbered entities with a WalkBlock component of the same id
local MAX_BLOCKS = 64
local Floor = {}

export type Floor = Movement.NavMesh & {
	randomPoint: (self: any, options: { center: vector?, radius: number?, extents: vector? }?) -> vector?,
}

local function number(v: unknown, default: number): number
	return if type(v) == "number" and v == v and math.abs(v) < math.huge then v else default
end

export type Block = { minX: number, maxX: number, minZ: number, maxZ: number }

-- [point] moved out of every block it stands in, by the shortest way.
local function outside(x: number, z: number, blocks: {Block}): (number, number)
	for _ = 1, 3 do
		local moved = false
		for _, b in blocks do
			if x > b.minX and x < b.maxX and z > b.minZ and z < b.maxZ then
				local left, right, back, front = x - b.minX, b.maxX - x, z - b.minZ, b.maxZ - z
				local least = math.min(left, right, back, front)
				if least == left then x = b.minX elseif least == right then x = b.maxX
				elseif least == back then z = b.minZ else z = b.maxZ end
				moved = true
			end
		end
		if not moved then break end
	end
	return x, z
end

function Floor.rectangle(center: vector, width: number, depth: number, blocks: {Block}?): Floor
	local minX, maxX = center.x - width / 2, center.x + width / 2
	local minZ, maxZ = center.z - depth / 2, center.z + depth / 2
	local y = center.y
	local solid = blocks or {}
	local function clamp(point: vector): vector
		local x, z = outside(math.clamp(point.x, minX, maxX), math.clamp(point.z, minZ, maxZ), solid)
		return vector.create(math.clamp(x, minX, maxX), y, math.clamp(z, minZ, maxZ))
	end
	local floor = {}
	function floor.nearestPoint(_self: any, point: vector, _extents: vector?): vector?
		return clamp(point)
	end
	function floor.findPath(_self: any, _from: vector, to: vector, _extents: vector?): {vector}?
		return { clamp(to) }
	end
	function floor.moveAlongSurface(_self: any, _from: vector, to: vector, _extents: vector?): vector?
		return clamp(to)
	end
	function floor.randomPoint(_self: any, options: { center: vector?, radius: number?, extents: vector? }?): vector?
		local around, radius = if options then options.center else nil, if options then options.radius else nil
		if around and radius then
			local angle, distance = math.random() * 2 * math.pi, math.sqrt(math.random()) * radius
			return clamp(around + vector.create(math.cos(angle) * distance, 0, math.sin(angle) * distance))
		end
		return clamp(vector.create(minX + math.random() * (maxX - minX), y, minZ + math.random() * (maxZ - minZ)))
	end
	return (floor :: any) :: Floor
end

-- [world]'s floor; nil when it has neither a navmesh nor a walk area.
function Floor.of(world: scenes.Scene): Floor?
	local mesh = world.navMesh
	if mesh and mesh.isValid and mesh:bounds() then return (mesh :: any) :: Floor end
	local area = world:getAuthored(AREA)
	if not area then return nil end
	local settings = area:component(AREA)
	local properties: {read [string]: unknown} = if settings then settings.properties else {}
	local blocks: {Block} = {}
	for i = 1, MAX_BLOCKS do
		local entity = world:getAuthored(BLOCK .. i)
		if not entity then break end
		local block = entity:component(BLOCK .. i)
		local props: {read [string]: unknown} = if block then block.properties else {}
		local at = entity:worldPosition()
		local w, d = math.max(0.1, number(props.width, 1)) / 2, math.max(0.1, number(props.depth, 1)) / 2
		table.insert(blocks, { minX = at.x - w, maxX = at.x + w, minZ = at.z - d, maxZ = at.z + d })
	end
	return Floor.rectangle(area:worldPosition(), math.max(0.5, number(properties.width, 10)), math.max(0.5, number(properties.depth, 10)), blocks)
end

return table.freeze(Floor)
