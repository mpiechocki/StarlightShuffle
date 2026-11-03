--!strict
--@server
-- Carries chat between the places of one chat: a lobby and the mini-game
-- places its players are off in (server/Chat's `share` and `heard`). The chat
-- is named by its lobby's instance id (`use`: the lobby's own, a mini-game's
-- from its group's arrival). Each message is appended to a short list in
-- @moonbase/storage, numbered, and the chat's channel hears a hint; every
-- place of the chat reads what is new on a hint, on a resync and every POLL
-- seconds besides (a hint can be lost), and hands on what other places said.
-- A place starts from what is there when it joins: nothing said before
-- reaches it. The list keeps the last 50 and outlives a quiet chat by an hour
-- (in the datastore bodies below).
local server = require("@moonbase/server")
local storage = require("@moonbase/storage")
local hosting = require("@moonbase/hosting")
local json = require("@moonbase/json")
local Net = require("../shared/Net")
local Chat = require("./Chat")

local POLL = 4 -- seconds between reads without a hint

export type Relay = {
	-- Joins the chat of the lobby [lobby] (only the first call counts).
	use: (lobby: string) -> (),
	-- Hands [message], allowed here, to the chat's other places.
	share: (message: Chat.Shared) -> (),
	dispose: () -> (),
}

-- These bodies run on the datastore (Lua 5.1, store commands only).
local postOperation = storage.define({
	name = "chat_post",
	run = function(store: storage.Store, _context: storage.Context, args: {lobby: string, entry: string}): number
		local list, counter = store.key("chat", args.lobby), store.key("chat", args.lobby, "seq")
		local seq = store.INCR(counter)
		store.RPUSH(list, store.string(seq) .. "|" .. args.entry)
		store.LTRIM(list, -50, -1)
		store.EXPIRE(list, 3600)
		store.EXPIRE(counter, 3600)
		store.PUBLISH(list, seq)
		return seq
	end,
})

local readOperation = storage.define({
	name = "chat_read",
	run = function(store: storage.Store, _context: storage.Context, args: {lobby: string}): {string}
		return store.LRANGE(store.key("chat", args.lobby), 0, -1)
	end,
})

-- An entry as stored: "<seq>|<json>"; its number and message, or nil.
local function parse(raw: unknown): (number?, string?, Chat.Shared?)
	if type(raw) ~= "string" then return nil, nil, nil end
	local bar = string.find(raw, "|", 1, true)
	local seq = if bar then tonumber(string.sub(raw, 1, bar - 1)) else nil
	if not bar or not seq then return nil, nil, nil end
	local ok, decoded = pcall(json.decode, string.sub(raw, bar + 1))
	if not ok or type(decoded) ~= "table" then return seq, nil, nil end
	local v = decoded :: {[string]: unknown}
	local player, name, text = Net.id(v.player), v.name, Net.text(v.text)
	if not player or player <= 0 or type(name) ~= "string" or #name == 0 or #name > 64 or not text then return seq, nil, nil end
	local from = if type(v.from) == "string" then v.from else nil
	return seq, from, { player = player, name = name, text = text, roles = Net.roles(v.roles),
		id = Net.messageId(v.id), avatar = Net.avatarId(v.avatar) }
end

local ChatRelay = {}

-- Hands what other places say to [heard].
function ChatRelay.new(heard: (message: Chat.Shared) -> ()): Relay
	local lobby: string? = nil
	local last: number? = nil -- the newest entry seen (nil: not read yet)
	local reading, again, closed = false, false, false
	local unsubscribe: (() -> ())? = nil
	local stopPoll: (() -> ())? = nil
	local me = server.context.instance_id

	local function read()
		local name = lobby
		if not name or closed then return end
		if reading then again = true; return end
		reading = true
		readOperation:call({ lobby = name }, function(result)
			reading = false
			if closed then return end
			if result.ok then
				local first = last == nil
				for _, raw in result.value or {} do
					local seq, from, message = parse(raw)
					if seq and (last == nil or seq > (last :: number)) then
						last = seq
						-- Joining: only what comes from now on.
						if not first and message and from ~= me then heard(message) end
					end
				end
				if first and last == nil then last = 0 end
			else
				print("Reading the chat failed: " .. result.error.message)
			end
			if again then again = false; read() end
		end)
	end

	local function poll()
		stopPoll = server.after(POLL, function()
			read()
			if not closed then poll() end
		end)
	end

	return {
		use = function(id: string)
			if lobby or closed or #id == 0 then return end
			lobby = id
			unsubscribe = hosting.subscribe({ kind = "channel", key = storage.key("chat", id) }, function(_event)
				read()
			end)
			read()
			poll()
		end,
		share = function(message: Chat.Shared)
			local name = lobby
			if not name or closed then return end
			local ok, entry = pcall(json.encode, { from = me, player = message.player, name = message.name, text = message.text,
				roles = message.roles, id = message.id, avatar = message.avatar })
			if not ok then return end
			postOperation:call({ lobby = name, entry = entry }, function(result)
				if not result.ok then print("Sharing a chat message failed: " .. result.error.message) end
			end)
		end,
		dispose = function()
			closed = true
			if unsubscribe then unsubscribe(); unsubscribe = nil end
			if stopPoll then stopPoll(); stopPoll = nil end
		end,
	}
end

return table.freeze(ChatRelay)
