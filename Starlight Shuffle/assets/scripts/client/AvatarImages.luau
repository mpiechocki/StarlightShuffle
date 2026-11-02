--!strict
--@client
-- Avatar thumbnail URLs from their media ids. The app's own AuthUser model
-- builds them (`<cdn>/media/avatar/<id>`), so they follow the app's CDN.
local models = require("@es/models")
local json = require("@moonbase/json")

local MAX_CACHED = 256
local cache: {[string]: string} = {}
local cached = 0

local AvatarImages = {}

-- The thumbnail URL for media id [avatar] (already validated by Net.avatarId).
function AvatarImages.url(avatar: string): string?
	local url = cache[avatar]
	if url then return url end
	local user = models.AuthUser.fromJsonOne(json.encode({ avatar_id = avatar }))
	if not user then return nil end
	url = user:getAvatarUrl()
	if cached >= MAX_CACHED then table.clear(cache); cached = 0 end
	cache[avatar], cached = url, cached + 1
	return url
end

return table.freeze(AvatarImages)
