--!strict
--@client
-- Attached to the star_pass scene: the approved garden backdrop and pixel
-- star (originals in art/star_pass/) and the audio (original, synthesized by
-- tools/star_pass_audio.py), handed to Assets while the scene shows.
local engine = require("@moonbase/engine")
local Assets = require("./Assets")

--@property
local garden: engine.Texture? = nil
--@property
local star: engine.Texture? = nil
--@property
local music: engine.AudioClip? = nil
--@property
local tick: engine.AudioClip? = nil
--@property
local tock: engine.AudioClip? = nil
--@property
local catch: engine.AudioClip? = nil
--@property
local pass: engine.AudioClip? = nil
--@property
local burst: engine.AudioClip? = nil

return engine.defineScript({
	onStart = function()
		Assets.set({ garden = garden, star = star, music = music, tick = tick, tock = tock, catch = catch, pass = pass, burst = burst })
	end,
	onDestroy = function()
		Assets.set({})
	end,
})
