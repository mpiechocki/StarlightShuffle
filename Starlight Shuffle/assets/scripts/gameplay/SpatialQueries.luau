--!strict
--@client
local engine = require("@moonbase/engine")
local Spatial = {}
Spatial.__index = Spatial

export type Label = { x: number, y: number, text: string }
type Fields = {
	scene: engine.Scene, player: engine.Entity,
	selection: engine.Entity?, triggerOptions: engine.RaycastOptions,
}
export type Controller = typeof(setmetatable({} :: Fields, Spatial))

function Spatial.new(scene: engine.Scene, player: engine.Entity): Controller
	return setmetatable({
		scene = scene, player = player, selection = nil,
		-- Trigger selection is independent of the collision event matrix.
		triggerOptions = engine.RaycastOptions({target = engine.QueryTarget.colliders,
			maxDistance = 100, layers = {"Interactable"}, triggerMode = engine.TriggerQuery.only,
			excludeEntities = {player}}),
	} :: Fields, Spatial)
end

function Spatial.selectTrigger(self: Controller, x: number, y: number): engine.Entity?
	local scene = self.scene
	if not scene.isValid then return nil end
	local viewport, camera = scene.viewport, scene.activeCamera
	self.selection = nil
	if not viewport or not camera then return nil end
	local hit = scene.queries:raycast({
		ray = camera:screenPointToRay({x = x, y = y, viewport = viewport}),
		options = self.triggerOptions,
	})
	self.selection = if hit then hit.entity else nil
	return self.selection
end

-- Explicit geometric blocker policy: furniture meshes block sight; the player
-- and the selected prop (including their children) are excluded. Alpha holes,
-- masks and fading pixels are not sampled. This is an informational indicator.
function Spatial.hasLineOfSight(self: Controller, target: engine.Entity, point: vector): boolean
	local scene = self.scene
	if not scene.isValid or not target.isValid or not self.player.isValid then return false end
	local origin = self.player.transform.worldPosition + vector.create(0, 1.2, 0)
	local delta = point - origin
	local distance = vector.magnitude(delta)
	if distance <= 0.001 then return true end
	return not scene.queries:raycastAny({ray = engine.Ray({origin = origin, direction = delta}),
		options = engine.RaycastOptions({target = engine.QueryTarget.meshes,
			minDistance = 0.001, maxDistance = distance, excludeEntities = {self.player, target}}),
	})
end

function Spatial.label(self: Controller): Label?
	local scene = self.scene
	if not scene.isValid then return nil end
	local viewport, camera = scene.viewport, scene.activeCamera
	if not viewport or not camera then return nil end
	local selected = self.selection
	local entity = if selected and selected.isValid and selected.enabled then selected else self.player
	if not entity.isValid or not entity.enabled then return nil end
	local bounds = scene.queries:rendererBounds({entity = entity, camera = camera})
	if not entity.enabled then return nil end
	local center = if bounds then bounds.center else entity.transform.worldPosition + vector.create(0, 1, 0)
	local anchor = if bounds then vector.create(center.x, bounds.max.y + 0.15, center.z)
		else center + vector.create(0, 1, 0)
	local projected = camera:worldToScreen({point = anchor, viewport = viewport})
	if not projected or not projected.insideFrustum then return nil end
	local text = entity.name
	if selected == entity and not self:hasLineOfSight(entity, center) then text ..= " · blocked" end
	return {x = projected.x, y = projected.y, text = text}
end

return Spatial
