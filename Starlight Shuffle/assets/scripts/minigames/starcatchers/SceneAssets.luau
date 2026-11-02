--!strict
--@client
-- Attached to the starcatchers scene: the approved galaxy sky (original in
-- art/starcatchers/) and the audio (original, synthesized by
-- tools/starcatchers_audio.py), handed to Assets while the scene shows.
local engine = require("@moonbase/engine")
local Assets = require("./Assets")

--@property
local galaxy: engine.Texture? = nil
--@property
local music: engine.AudioClip? = nil
--@property
local hook: engine.AudioClip? = nil
--@property
local bank: engine.AudioClip? = nil
--@property
local snap: engine.AudioClip? = nil

return engine.defineScript({
	onStart = function()
		Assets.set({ galaxy = galaxy, music = music, hook = hook, bank = bank, snap = snap })
	end,
	onDestroy = function()
		Assets.set({})
	end,
})
