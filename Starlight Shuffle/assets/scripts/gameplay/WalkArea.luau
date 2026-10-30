--!strict
-- Marks the walkable floor of a scene that has no baked navmesh yet: a
-- rectangle centred on this entity, [width] along X and [depth] along Z,
-- standing at its height. shared/Floor reads it on both sides. Once the scene
-- has a baked navmesh (Scene → Bake navmesh), that is used instead.
local scenes = require("@moonbase/scene")
--@property(min = 0.5)
local width: number = 10
--@property(min = 0.5)
local depth: number = 10
return scenes.defineScript(function(_component)
	return {}
end)
