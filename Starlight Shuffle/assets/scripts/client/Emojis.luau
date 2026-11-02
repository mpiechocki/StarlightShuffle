--!strict
--@client
-- The app's custom (Everskies) emoji by name. Chat carries `:name:` codes and
-- each client draws them from this catalog, loaded once per session; a failed
-- load can be retried. [revision] counts loads, so drawn text can tell when
-- it shows codes the catalog now knows. Each emoji also has a private-use
-- character for this session ([char]), which the chat bar's text holds in
-- place of its code (widgets/EmojiInput); it never leaves the client.
local api = require("@es/api")
local models = require("@es/models")

export type Emoji = { read name: string, read url: string, read char: number }
export type Status = "idle" | "loading" | "ready" | "failed"
-- What drawing and editing emoji text looks up; the session's catalog, or a
-- test's own.
export type Catalog = {
	read find: (name: string) -> Emoji?,
	read byChar: (char: number) -> Emoji?,
	read all: () -> {Emoji},
}

-- The first private-use character; the area holds 6400.
local FIRST_CHAR = 0xE000
local LAST_CHAR = 0xF8FF

local Emojis = {}
local list: {Emoji} = {}
local byName: {[string]: Emoji} = {}
local byChar: {[number]: Emoji} = {}
local status: Status = "idle"
local revision = 0
local listeners: {[() -> ()]: boolean} = {}

local function changed()
	for listener in listeners do listener() end
end

-- Loads the catalog unless it is loaded or loading. Listeners hear when it
-- finishes or fails, never from this call (it may run while widgets build), so
-- a caller showing the loading state redraws itself.
function Emojis.load()
	if status == "loading" or status == "ready" then return end
	status = "loading"
	api.rest:query("site/general/emoji")
		:withParsers({multi = models.Emoji.fromJsonAll, single = models.Emoji.fromJsonOne})
		:filter({api.Search.equals("type", models.Emoji.TYPE_CUSTOM)})
		:limit(0)
		:all()
		:andThen(function(found: {read models.Emoji})
			local loaded: {Emoji}, named: {[string]: Emoji}, chars: {[number]: Emoji} = {}, {}, {}
			for _, emoji in found do
				local name = emoji.name
				local char = FIRST_CHAR + #loaded
				-- Only names a shortcode can spell, each once.
				if name and emoji.media_id and emoji.type == models.Emoji.TYPE_CUSTOM
					and string.match(name, "^[%w_]+$") and not named[name] and char <= LAST_CHAR then
					local entry = { name = name, url = emoji:getImageUrl(), char = char }
					named[name], chars[char] = entry, entry
					table.insert(loaded, entry)
				end
			end
			list, byName, byChar, status = loaded, named, chars, "ready"
			revision += 1
			changed()
		end, function(err: unknown, _stack: unknown)
			status = "failed"
			print("Emoji failed to load: " .. tostring(err))
			changed()
		end)
end

function Emojis.status(): Status return status end

-- How many times the catalog has loaded.
function Emojis.revision(): number return revision end

-- Loaded emoji, in catalog order.
function Emojis.all(): {Emoji} return list end

-- A loaded emoji by name.
function Emojis.find(name: string): Emoji? return byName[name] end

-- The loaded emoji a private-use character stands for.
function Emojis.byChar(char: number): Emoji? return byChar[char] end

-- A loaded emoji's image URL.
function Emojis.url(name: string): string?
	local emoji = byName[name]
	return if emoji then emoji.url else nil
end

-- Calls [listener] whenever a load finishes or fails; returns the unsubscribe.
function Emojis.subscribe(listener: () -> ()): () -> ()
	listeners[listener] = true
	return function() listeners[listener] = nil end
end

return table.freeze(Emojis)
