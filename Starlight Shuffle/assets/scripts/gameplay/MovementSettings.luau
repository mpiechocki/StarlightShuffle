--!strict
local scene = require("@moonbase/scene")
--@property(min=0.01)
local speed: number = 4.7
--@property(min=0)
local stoppingDistance: number = 0.05
-- The controller owns stepping; these are authored movement parameters only.
return scene.defineScript(function(_component)
    return {}
end)
