--!strict
--@client
-- Attached to the blast_mining scene: the cave backdrop and the audio (an
-- original synthesized work-song loop and four effects; tools/blast_mining_audio.py
-- makes them), handed to Assets while the scene shows. Replace any of them
-- here in the inspector.
local engine = require("@moonbase/engine")
local Assets = require("./Assets")

--@property
local cave: engine.Texture? = nil
--@property
local music: engine.AudioClip? = nil
--@property
local rock: engine.AudioClip? = nil
--@property
local gem: engine.AudioClip? = nil
--@property
local bomb: engine.AudioClip? = nil
--@property
local swing: engine.AudioClip? = nil

return engine.defineScript({
	onStart = function()
		Assets.set({ cave = cave, music = music, rock = rock, gem = gem, bomb = bomb, swing = swing })
	end,
	onDestroy = function()
		Assets.set({})
	end,
})
