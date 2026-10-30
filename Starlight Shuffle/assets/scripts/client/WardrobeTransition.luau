--!strict
--@client
local core=require('@dart/core')
local animation=require('@flutter/animation')
return table.freeze({
    -- Match the HTML reference: quick UI entrance, then a soft camera settle.
    cameraResponse=6,
    frameResponse=8,
    entranceRise=12,
    entranceDuration=core.Duration({milliseconds=200}),
    duration=core.Duration({milliseconds=220}),
    curve=animation.Cubic({a=.2,b=.7,c=.2,d=1}),
})
