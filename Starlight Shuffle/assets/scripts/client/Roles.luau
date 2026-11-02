--!strict
--@client
-- The platform's roles by name, shown as the app shows them beside a player's
-- name: the first of a player's roles colours it, and each role with an icon
-- shows that icon after it. Players carry their roles' names (Net.roles);
-- what each looks like comes from the app's `general` data, loaded once per
-- session. [revision] counts loads, so drawn names can tell when they are
-- out of date.
local api = require("@es/api")
local models = require("@es/models")
local json = require("@moonbase/json")
local Net = require("../shared/Net")

-- [color] is 0xRRGGBB; [icon] the icon's URL.
export type Role = { read color: number?, read icon: string? }
export type Catalog = {read [string]: Role}
export type Status = "idle" | "loading" | "ready" | "failed"

local Roles = {}
local catalog: Catalog = {}
local status: Status = "idle"
local revision = 0
local listeners: {[() -> ()]: boolean} = {}

-- The icon URL for media id [id], built by the app's own model so it follows
-- the app's CDN.
local function iconUrl(id: string): string?
	local item = models.AuthItem.fromJsonOne(json.encode({ icon_id = id }))
	return if item then item:getIconUrl() else nil
end

-- The roles in the app's `general` data (its `roles`, by name), each with
-- its flavour's `#rrggbb` colour and its `icon_id` made a URL by [icon].
-- Entries that are not well formed are left out, as are their bad parts.
function Roles.parse(data: unknown, icon: (id: string) -> string?): Catalog
	local out: {[string]: Role} = {}
	local roles = if type(data) == "table" then (data :: {[unknown]: unknown}).roles else nil
	if type(roles) ~= "table" then return out end
	for key, entry in roles :: {[unknown]: unknown} do
		local name = Net.role(key)
		if not name or type(entry) ~= "table" then continue end
		local fields = entry :: {[unknown]: unknown}
		local flavor = fields.flavor
		local hex = if type(flavor) == "table" then (flavor :: {[unknown]: unknown}).color else nil
		local color = if type(hex) == "string" and string.match(hex, "^#%x%x%x%x%x%x$")
			then tonumber(string.sub(hex, 2), 16) else nil
		-- A media id has an avatar id's shape: one safe path segment.
		local id = Net.avatarId(fields.icon_id)
		out[name] = { color = color, icon = if id then icon(id) else nil }
	end
	return out
end

-- Loads the catalog unless it is loaded or loading. Listeners hear when it
-- finishes, never from this call. Until then (or when it fails) names show
-- plain.
function Roles.load()
	if status == "loading" or status == "ready" then return end
	status = "loading"
	api.rest:get({ path = "general" }):andThen(function(data: unknown?)
		catalog, status = Roles.parse(data, iconUrl), "ready"
		revision += 1
		for listener in listeners do listener() end
	end, function(err: unknown, _stack: unknown)
		status = "failed"
		print("Roles failed to load: " .. tostring(err))
	end)
end

-- How many times the catalog has loaded.
function Roles.revision(): number return revision end

-- The colour (0xRRGGBB) a player with [roles] has their name in, if any:
-- their first role's. [from] stands in for the session's catalog.
function Roles.color(roles: {string}?, from: Catalog?): number?
	local first = if roles then roles[1] else nil
	local role = if first then (from or catalog)[first] else nil
	return if role then role.color else nil
end

-- The icon URLs of [roles] that have one, in order. Everyone is a "User",
-- which the app never shows.
function Roles.icons(roles: {string}?, from: Catalog?): {string}
	local urls: {string} = {}
	for _, name in roles or {} do
		local role = (from or catalog)[name]
		if role and role.icon and name ~= "User" then table.insert(urls, role.icon) end
	end
	return urls
end

-- Calls [listener] whenever a load finishes; returns the unsubscribe.
function Roles.subscribe(listener: () -> ()): () -> ()
	listeners[listener] = true
	return function() listeners[listener] = nil end
end

return table.freeze(Roles)
