--!strict
--@server
-- The chat, ported from Sky Lounge's server/Relay: messages and typing,
-- relayed between every pair here that may talk. One chat spans a lobby and
-- every mini-game its players are off playing: a message allowed here is also
-- handed to the host's `share` (server/ChatRelay carries it to those places),
-- and messages said there arrive through `heard`, for everyone here who may
-- hear their speaker (typing stays in its own place). A pair with a block either way
-- never hears from each other (their avatars still share the lobby), and a
-- joiner hears nobody until its relations arrive (or take too long). Chat
-- reaches others only once the platform's moderation allows it, in the order
-- each player said it; the sender sees their own at once. A muted player
-- (`muted` metadata) is heard only by themselves, and their typing is not
-- shown. Nothing said is kept: a joiner hears only what is said after it
-- arrives. The platform keeps what it moderates, under the id others receive
-- the message with, so they can report it. Every platform call fails open: an
-- error, a timeout or no platform (local Play) delivers the chat and hides
-- nobody. Takes the host as a parameter, so tests can drive it with a fake one.
local types = require("@moonbase/types")
local Social = require("@moonbase/social")
local Net = require("../shared/Net")

local RELATIONS_WAIT = 5 -- seconds a joiner waits for its relations before it hears everyone
local CHAT_WAIT = 5 -- seconds a message waits for moderation before it goes out anyway

export type Player = types.Player
export type Host = {
	-- Sends to [to], which is never empty.
	send: (to: {Player}, ...types.Value) -> (),
	clock: () -> number,
	after: (seconds: number, callback: () -> ()) -> () -> (),
	platform: Social.Social,
	-- The chat room moderators see.
	room: () -> Social.Room,
	-- Hands an allowed message to the other places of this chat, if any.
	share: ((message: Shared) -> ())?,
}
-- A message said in another place of this chat: by account [player] (their
-- thumbnail's media id [avatar], if any), with the platform's [id], if it keeps it.
export type Shared = { player: number, name: string, text: string, roles: {string}, id: string?, avatar: string? }
export type Chat = {
	added: (player: Player) -> (),
	removed: (player: Player) -> (),
	-- Takes SAY and TYPING; false for any other message.
	receive: (player: Player, kind: unknown, a: unknown) -> boolean,
	metadataChanged: (player: Player, changed: {string}) -> (),
	-- Whether [a] and [b] (session ids) hear each other.
	hears: (a: number, b: number) -> boolean,
	-- A message said in another place of this chat.
	heard: (message: Shared) -> (),
	dispose: () -> (),
}

-- `id` is the platform's, when it keeps chat.
type Said = { text: string, id: string?, decided: boolean, allowed: boolean }
type Peer = {
	player: Player, id: number, pid: number, name: string, avatar: string?, muted: boolean, roles: {string},
	typing: boolean, saidAt: number?,
	-- Hears nobody until its relations are known; `asked` numbers the queries.
	ready: boolean, asked: number,
	-- Messages waiting for moderation, in the order they were said.
	pending: {Said},
}

local function field(player: Player, key: string): unknown
	local metadata: unknown = player.metadata
	return if type(metadata) == "table" then (metadata :: {[string]: unknown})[key] else nil
end

local Chat = {}

function Chat.new(host: Host): Chat
	local peers: {[number]: Peer} = {} -- by session id
	-- Player ids with a block either way, both ways round.
	local blocked: {[number]: {[number]: boolean}} = {}
	local closed = false
	-- Speakers elsewhere whose relations with everyone here were asked for
	-- (true once known), and what they said meanwhile, in order.
	local remote: {[number]: boolean} = {}
	local held: {[number]: {Shared}} = {}

	local function send(to: {Player}, ...: types.Value)
		if #to > 0 and not closed then host.send(to, ...) end
	end

	local function isBlocked(a: number, b: number): boolean
		local row = blocked[a]
		return row ~= nil and row[b] == true
	end

	local function setBlocked(a: number, b: number, on: boolean)
		for _, ends in {{a, b}, {b, a}} do
			local row = blocked[ends[1]]
			if on then
				if not row then row = {}; blocked[ends[1]] = row end
				row[ends[2]] = true
			elseif row then
				row[ends[2]] = nil
				if next(row) == nil then blocked[ends[1]] = nil end
			end
		end
	end

	local function hears(a: Peer, b: Peer): boolean
		return a ~= b and a.ready and b.ready and not isBlocked(a.pid, b.pid)
	end

	-- Everyone who hears [peer], besides themselves.
	local function audience(peer: Peer): {Player}
		local out: {Player} = {}
		for _, other in peers do
			if hears(peer, other) then table.insert(out, other.player) end
		end
		return out
	end

	-- Tells [to] whether [about], who it could not hear, is typing.
	local function introduce(to: Peer, about: Peer)
		if about.typing and not about.muted then send({to.player}, Net.TYPING, about.id, true) end
	end

	-- A fresh answer about [peer] decides every pair it is in.
	local function settle(peer: Peer, asked: number, relations: Social.Relations?, among: {number})
		if closed or peers[peer.id] ~= peer or asked ~= peer.asked then return end
		local before: {[Peer]: boolean} = {}
		for _, other in peers do before[other] = hears(peer, other) end
		if relations then
			for _, pid in among do setBlocked(peer.pid, pid, relations.blocked[pid] == true) end
		end
		peer.ready = true
		for _, other in peers do
			if hears(peer, other) and not before[other] then
				introduce(peer, other)
				introduce(other, peer)
			end
		end
	end

	-- Asks for [peer]'s relations with everyone here.
	local function ask(peer: Peer)
		peer.asked += 1
		local asked = peer.asked
		local among: {number} = {}
		local seen: {[number]: boolean} = {[peer.pid] = true}
		for _, other in peers do
			if not seen[other.pid] then
				seen[other.pid] = true
				table.insert(among, other.pid)
			end
		end
		-- And whoever spoke from another place: they may speak again.
		for pid in remote do
			if not seen[pid] then
				seen[pid] = true
				table.insert(among, pid)
			end
		end
		local finished = false
		local cancel = host.after(RELATIONS_WAIT, function()
			if finished then return end
			finished = true
			print("Chat relations for a player timed out; hearing everyone")
			settle(peer, asked, nil, among)
		end)
		host.platform.relations(peer.pid, among, function(relations: Social.Relations?)
			if finished then return end
			finished = true
			cancel()
			settle(peer, asked, relations, among)
		end)
	end

	-- Shows [peer]'s decided messages, in order, as far as the first undecided one.
	local function deliver(peer: Peer)
		while peer.pending[1] and peer.pending[1].decided do
			local said = table.remove(peer.pending, 1) :: Said
			if said.allowed and not peer.muted and peers[peer.id] == peer then
				local id = said.id
				if id then
					send(audience(peer), Net.SAY, peer.id, peer.name, said.text, Net.roleList(peer.roles), id)
				else
					send(audience(peer), Net.SAY, peer.id, peer.name, said.text, Net.roleList(peer.roles))
				end
				local share = host.share
				if share then
					share({ player = peer.pid, name = peer.name, text = said.text, roles = peer.roles, id = id, avatar = peer.avatar })
				end
			end
		end
	end

	local function say(peer: Peer, raw: unknown)
		local text = Net.text(raw)
		local now = host.clock()
		if not text or (peer.saidAt and now - peer.saidAt < Net.CHAT_COOLDOWN) then return end
		peer.saidAt = now
		if peer.typing then
			peer.typing = false
			if not peer.muted then send(audience(peer), Net.TYPING, peer.id, false) end
		end
		-- The sender sees it at once; everyone else once it is allowed.
		send({peer.player}, Net.SAY, peer.id, peer.name, text, Net.roleList(peer.roles))
		if peer.muted then return end
		local id = host.platform.messageId()
		local said: Said = { text = text, id = id, decided = false, allowed = false }
		table.insert(peer.pending, said)
		local cancel: () -> () = function() end
		local function decide(allowed: boolean?)
			if said.decided then return end
			cancel()
			-- Undecided (an error, a timeout, no platform) goes out anyway.
			said.decided, said.allowed = true, allowed ~= false
			deliver(peer)
		end
		cancel = host.after(CHAT_WAIT, function()
			print("Chat moderation timed out; delivering")
			decide(nil)
		end)
		if id then host.platform.moderate(peer.pid, text, host.room(), id, decide) else decide(nil) end
	end

	-- [message] from elsewhere, to everyone here who may hear its speaker. Its
	-- speaker has no session here: clients get the negated account id.
	local function relay(message: Shared)
		local to: {Player} = {}
		for _, peer in peers do
			if peer.ready and peer.pid ~= message.player and not isBlocked(peer.pid, message.player) then
				table.insert(to, peer.player)
			end
		end
		send(to, Net.SAY, -message.player, message.name, message.text, Net.roleList(message.roles),
			message.id or false, message.player, message.avatar or false)
	end

	-- What a speaker elsewhere said while their relations were asked for, in order.
	local function release(pid: number)
		local waiting = held[pid]
		held[pid] = nil
		if waiting then for _, message in waiting do relay(message) end end
	end

	-- A new speaker elsewhere: their relations with everyone here first (the
	-- answer may come at once), what they said held until then.
	local function meet(pid: number, first: Shared)
		remote[pid] = false
		held[pid] = {first}
		local among: {number} = {}
		for _, peer in peers do
			if peer.pid ~= pid and not table.find(among, peer.pid) then table.insert(among, peer.pid) end
		end
		local finished = false
		local function settled(relations: Social.Relations?)
			if finished or closed then return end
			finished = true
			if relations then
				for _, other in among do setBlocked(pid, other, relations.blocked[other] == true) end
			end
			remote[pid] = true
			release(pid)
		end
		local cancel = host.after(RELATIONS_WAIT, function()
			if not finished then print("Chat relations for a remote speaker timed out; hearing them") end
			settled(nil)
		end)
		host.platform.relations(pid, among, function(relations: Social.Relations?)
			cancel()
			settled(relations)
		end)
	end

	-- Where [peer]'s reports of others' chat go.
	local function hello(peer: Peer)
		local experience = host.platform.experience
		if experience then send({peer.player}, Net.CHAT, experience) else send({peer.player}, Net.CHAT) end
	end

	return {
		added = function(player: Player)
			local peer: Peer = {
				player = player, id = player.session_id, pid = player.player_id, name = Net.name(player.metadata, player.player_id),
				avatar = Net.avatarId(field(player, "avatar_id")),
				muted = field(player, "muted") == true, roles = Net.roles(field(player, "display_roles")),
				typing = false, saidAt = nil, ready = false, asked = 0, pending = {},
			}
			peers[peer.id] = peer
			hello(peer)
			ask(peer)
		end,
		removed = function(player: Player)
			local peer = peers[player.session_id]
			if not peer then return end
			peers[player.session_id] = nil
			-- Typing dots go with their avatar (client/Chat); nothing to tell.
			table.clear(peer.pending)
		end,
		receive = function(player: Player, kind: unknown, a: unknown): boolean
			if kind ~= Net.SAY and kind ~= Net.TYPING then return false end
			-- Late messages from a player who already left are dropped.
			local peer = peers[player.session_id]
			if not peer then return true end
			if kind == Net.SAY then
				say(peer, a)
			elseif type(a) == "boolean" and a ~= peer.typing then
				peer.typing = a
				if not peer.muted then send(audience(peer), Net.TYPING, peer.id, a) end
			end
			return true
		end,
		metadataChanged = function(player: Player, changed: {string})
			local peer = peers[player.session_id]
			if not peer then return end
			local keys: {[string]: boolean} = {}
			for _, key in changed do keys[key] = true end
			if keys.alias then peer.name = Net.name(player.metadata, player.player_id) end
			if keys.display_roles then peer.roles = Net.roles(field(player, "display_roles")) end
			if keys.muted then
				local muted = field(player, "muted") == true
				if muted ~= peer.muted then
					peer.muted = muted
					-- A typist who is muted stops showing as one, and the other way round.
					if peer.typing then send(audience(peer), Net.TYPING, peer.id, not muted) end
				end
			end
			if keys.relations_rev then ask(peer) end
		end,
		hears = function(a: number, b: number): boolean
			local x, y = peers[a], peers[b]
			return x ~= nil and y ~= nil and hears(x, y)
		end,
		heard = function(message: Shared)
			if closed then return end
			local known = remote[message.player]
			if known == true then relay(message)
			elseif known == nil then meet(message.player, message)
			else
				local waiting = held[message.player]
				if waiting then table.insert(waiting, message) end
			end
		end,
		dispose = function()
			closed = true
			table.clear(peers)
			table.clear(held)
		end,
	}
end

return table.freeze(Chat)
