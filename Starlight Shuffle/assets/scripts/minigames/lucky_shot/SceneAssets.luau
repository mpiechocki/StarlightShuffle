--!strict
--@client
-- Attached to the lucky_shot scene: the meadow backdrop and the audio (an
-- original synthesized loop and effects; tools/lucky_shot_audio.py makes
-- them), handed to Assets while the scene shows. Replace any of them here in
-- the inspector.
local engine = require("@moonbase/engine")
local Assets = require("./Assets")

--@property
local meadow: engine.Texture? = nil
--@property
local music: engine.AudioClip? = nil
--@property
local pop: engine.AudioClip? = nil
--@property
local popGold: engine.AudioClip? = nil
--@property
local thunder: engine.AudioClip? = nil
--@property
local twang: engine.AudioClip? = nil

return engine.defineScript({
	onStart = function()
		Assets.set({ meadow = meadow, music = music, pop = pop, popGold = popGold, thunder = thunder, twang = twang })
	end,
	onDestroy = function()
		Assets.set({})
	end,
})
