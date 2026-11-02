--!strict
--@client
-- A replicated avatar (prefabs/Avatar): its presentation root, the native
-- counterpart that owns its position, and the "visual" child whose
-- AvatarRenderer shows the outfit; the "aura" child's particles are the
-- shop's avatar glow, off until it is worn (client/Multiplayer).
local engine = require("@moonbase/engine")
local scenes = require("@moonbase/scene")
local Avatars = {}
export type Avatar = {entity: engine.Entity, native: scenes.Entity, visual: engine.Entity, renderer: engine.AvatarRendererComponent,
	aura: engine.ParticleEmitterComponent?, auraEntity: engine.Entity?}

-- [visuals] maps the prefab's authored entity IDs to their presentation entities.
function Avatars.from(entity: engine.Entity, native: scenes.Entity, visuals: {[string]: engine.Entity}): Avatar
	local visual = assert(visuals.visual, 'The avatar prefab needs a "visual" child')
	local aura = visuals.aura
	return {entity = entity, native = native, visual = visual,
		renderer = assert(visual.avatarRenderer, "The avatar visual needs an AvatarRenderer"),
		aura = if aura then aura.particleEmitter else nil, auraEntity = aura}
end

local MARGIN = 0.04 -- grace around an outfit's opaque box, in the avatar's own units
local SEE_THROUGH = 4 -- avatars a pick looks past before giving up
local CROWD = 8 -- as many, for a pick past whole avatars

-- Whether [point] (world space) on [entity]'s surface is part of something
-- solid: anything but an avatar's empty canvas. A pick hits an avatar's whole
-- canvas; its opaque box is the outfit's alpha bounds (contentBounds), which
-- span the canvas until the outfit has loaded.
local function solid(entity: engine.Entity, point: vector): boolean
	local renderer = entity.avatarRenderer
	local bounds = if renderer and renderer.isValid then renderer.contentBounds else nil
	if not bounds then return true end
	local p = entity.transform:worldToLocal(point)
	return p.x >= bounds.min.x - MARGIN and p.x <= bounds.max.x + MARGIN
		and p.y >= bounds.min.y - MARGIN and p.y <= bounds.max.y + MARGIN
end

-- The nearest hit under (x, y) that [past] doesn't look past, giving up after
-- [limit] of them.
local function nearest(scene: engine.Scene, camera: engine.CameraComponent, viewport: engine.Viewport, x: number, y: number,
	exclude: {engine.Entity}, limit: number, past: (hit: engine.RaycastHit) -> boolean): engine.RaycastHit?
	local skipped = table.clone(exclude)
	for _ = 0, limit do
		local hit = scene.queries:pick({camera = camera, viewport = viewport, x = x, y = y,
			excludeEntities = if #skipped > 0 then skipped else nil, includeDescendants = true})
		if not hit or not past(hit) then return hit end
		table.insert(skipped, hit.entity)
	end
	return nil
end

-- The nearest surface under (x, y), like scene.queries:pick, seeing through
-- the empty margins of avatars' canvases to whatever stands behind them.
function Avatars.pick(scene: engine.Scene, camera: engine.CameraComponent, viewport: engine.Viewport, x: number, y: number,
	exclude: {engine.Entity}): engine.RaycastHit?
	return nearest(scene, camera, viewport, x, y, exclude, SEE_THROUGH, function(hit: engine.RaycastHit): boolean
		return not solid(hit.entity, hit.position)
	end)
end

-- The nearest surface under (x, y) that isn't an avatar at all: a tap on the
-- lounge reaches what stands behind whoever is in front of it.
function Avatars.pickPast(scene: engine.Scene, camera: engine.CameraComponent, viewport: engine.Viewport, x: number, y: number,
	exclude: {engine.Entity}): engine.RaycastHit?
	return nearest(scene, camera, viewport, x, y, exclude, CROWD, function(hit: engine.RaycastHit): boolean
		local renderer = hit.entity.avatarRenderer
		return renderer ~= nil and renderer.isValid
	end)
end

return table.freeze(Avatars)
