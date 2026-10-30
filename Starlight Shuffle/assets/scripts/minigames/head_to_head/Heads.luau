--!strict
--@client
-- The approved library heads' artwork on this client, set by the head_to_head
-- scene's Library component once that scene shows (a texture property must sit
-- on a component of the scene that ships it). Listeners hear it arrive.
local engine = require("@moonbase/engine")

local Heads = {}
local textures: {engine.Texture} = {}
local listeners: {() -> ()} = {}

function Heads.set(list: {engine.Texture})
	textures = list
	for _, listener in table.clone(listeners) do listener() end
end

-- Library head [index] (1..Rules.LIBRARY), once the scene has supplied it.
function Heads.get(index: number): engine.Texture?
	return textures[index]
end

function Heads.listen(listener: () -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local at = table.find(listeners, listener)
		if at then table.remove(listeners, at) end
	end
end

return Heads
