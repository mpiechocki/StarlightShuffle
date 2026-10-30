--!strict
-- Where avatars may walk in a native scene: its baked navmesh when it has one,
-- else the rectangle its `walk-area` entity marks (gameplay/WalkArea), so a new
-- scene is playable before anyone bakes it. The rectangle has no obstacles:
-- avatars slide along its edges and walk through props on it. The server and
-- every client read the same floor, so movement checks agree.
local scenes = require("@moonbase/scene")
local Movement = require("@moonbase/movement")

local AREA = "walk-area" -- the entity, and its WalkArea component's id
local Floor = {}

export type Floor = Movement.NavMesh & {
	randomPoint: (self: any, options: { center: vector?, radius: number?, extents: vector? }?) -> vector?,
}

local function number(v: unknown, default: number): number
	return if type(v) == "number" and v == v and math.abs(v) < math.huge then v else default
end

local function rectangle(center: vector, width: number, depth: number): Floor
	local minX, maxX = center.x - width / 2, center.x + width / 2
	local minZ, maxZ = center.z - depth / 2, center.z + depth / 2
	local y = center.y
	local function clamp(point: vector): vector
		return vector.create(math.clamp(point.x, minX, maxX), y, math.clamp(point.z, minZ, maxZ))
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
		return vector.create(minX + math.random() * (maxX - minX), y, minZ + math.random() * (maxZ - minZ))
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
	return rectangle(area:worldPosition(), math.max(0.5, number(properties.width, 10)), math.max(0.5, number(properties.depth, 10)))
end

return table.freeze(Floor)
