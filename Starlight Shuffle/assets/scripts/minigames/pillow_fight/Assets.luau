--!strict
--@client
-- Pillow Fight's art and sound on this client, set by the pillow_fight scene's
-- SceneAssets component once that scene shows (a texture or clip property must
-- sit on a component of the scene that ships it). Listeners hear them arrive.
local engine = require("@moonbase/engine")

export type Kit = {
	bedroom: engine.Texture?, dolls: {engine.Texture},
	lullaby: engine.AudioClip?, throw: engine.AudioClip?, warning: engine.AudioClip?,
	hit: engine.AudioClip?, dodge: engine.AudioClip?,
}

local Assets = {}
local kit: Kit = { dolls = {} }
local listeners: {() -> ()} = {}

function Assets.set(next: Kit)
	kit = next
	for _, listener in table.clone(listeners) do listener() end
end

function Assets.get(): Kit
	return kit
end

function Assets.listen(listener: () -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local at = table.find(listeners, listener)
		if at then table.remove(listeners, at) end
	end
end

return Assets
