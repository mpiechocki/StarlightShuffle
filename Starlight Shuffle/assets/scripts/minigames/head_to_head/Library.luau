--!strict
--@client
-- Attached to the head_to_head scene: the approved library heads' artwork,
-- in library order (Rules.LIBRARY of them), handed to Heads while the scene shows.
local engine = require("@moonbase/engine")
local Heads = require("./Heads")

--@property
local heads: {engine.Texture} = {}

return engine.defineScript({
	onStart = function()
		Heads.set(heads)
	end,
	onDestroy = function()
		Heads.set({})
	end,
})
