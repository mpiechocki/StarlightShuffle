--!strict
--@client
-- Blast Mining's art and sound on this client, set by the blast_mining scene's
-- SceneAssets component once that scene shows (a texture or clip property must
-- sit on a component of the scene that ships it). Listeners hear them arrive.
local engine = require("@moonbase/engine")

export type Kit = {
	cave: engine.Texture?,
	music: engine.AudioClip?,
	rock: engine.AudioClip?, gem: engine.AudioClip?, bomb: engine.AudioClip?, swing: engine.AudioClip?,
}

local Assets = {}
local kit: Kit = {}
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
