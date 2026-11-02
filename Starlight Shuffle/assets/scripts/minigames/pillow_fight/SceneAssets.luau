--!strict
--@client
-- Attached to the pillow_fight scene: the approved bedroom backdrop, the three
-- bot avatars (originals in art/pillow_fight/) and the audio (original,
-- synthesized by tools/pillow_fight_audio.py), handed to Assets while the
-- scene shows.
local engine = require("@moonbase/engine")
local Assets = require("./Assets")

--@property
local bedroom: engine.Texture? = nil
--@property
local dolls: {engine.Texture} = {}
--@property
local lullaby: engine.AudioClip? = nil
--@property
local throw: engine.AudioClip? = nil
--@property
local warning: engine.AudioClip? = nil
--@property
local hit: engine.AudioClip? = nil
--@property
local dodge: engine.AudioClip? = nil

return engine.defineScript({
	onStart = function()
		Assets.set({ bedroom = bedroom, dolls = dolls, lullaby = lullaby, throw = throw, warning = warning, hit = hit, dodge = dodge })
	end,
	onDestroy = function()
		Assets.set({ dolls = {} })
	end,
})
