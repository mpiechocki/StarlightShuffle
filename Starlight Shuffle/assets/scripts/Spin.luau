--!strict
--@client
local engine = require('@moonbase/engine')

--@property(min = 0)
local speed: number = 0.45
local angle = 0
return engine.defineScript({
    onUpdate = function(dt: number)
        angle += dt * speed
        component.transform.rotation = vector.create(0, angle, 0)
    end,
})
