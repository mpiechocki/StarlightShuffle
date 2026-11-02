--!strict
-- Marks a rectangle of a walk area that avatars walk around (furniture on the
-- floor): [width] along X and [depth] along Z, centred on this entity. Its
-- entity must be named `walk-block-1`, `walk-block-2`, … in order; shared/Floor
-- reads them on both sides, while the scene uses its walk-area rectangle.
local scenes = require("@moonbase/scene")
--@property(min = 0.1)
local width: number = 1
--@property(min = 0.1)
local depth: number = 1
return scenes.defineScript(function(_component)
	return {}
end)
