--!strict
--@server
-- Who is in this place and how their avatars look: the name, outfit and
-- thumbnail every avatar's identity carries (server/Arena). An outfit in the
-- player's host metadata is their real one and beats the client's own LOOK;
-- the thumbnail comes only from the metadata's `avatar_id`. Their look from
-- the shop (server/Accounts) rides along once their account is read.
local types = require("@moonbase/types")
local Net = require("../shared/Net")
local Shop = require("../shared/Shop")

type Person = { player: types.Player, identity: Net.Identity, fixed: boolean }
export type People = {
	added: (player: types.Player) -> (),
	removed: (player: types.Player) -> (),
	-- Takes LOOK messages; false for any other.
	receive: (player: types.Player, kind: unknown, a: unknown) -> boolean,
	metadataChanged: (player: types.Player) -> (),
	-- What [player] wears from the shop.
	setLook: (player: types.Player, look: Shop.Look) -> (),
	identity: (session: number) -> Net.Identity?,
	name: (session: number) -> string?,
	-- Everyone here, by session id.
	all: () -> {[number]: types.Player},
	count: () -> number,
}

local function field(player: types.Player, key: string): unknown
	local metadata: unknown = player.metadata
	return if type(metadata) == "table" then (metadata :: {[string]: unknown})[key] else nil
end

local People = {}

function People.new(): People
	local people: {[number]: Person} = {}
	local count = 0

	local function describe(person: Person)
		local player = person.player
		local outfit = Net.outfit(field(player, "outfit"))
		person.fixed = outfit ~= nil
		-- A fresh record, so replication sees the identity part change.
		person.identity = { session = player.session_id, player = player.player_id,
			name = Net.name(player.metadata, player.player_id),
			outfit = outfit or person.identity.outfit, avatar = Net.avatarId(field(player, "avatar_id")),
			look = person.identity.look }
	end

	return {
		added = function(player: types.Player)
			if people[player.session_id] then return end
			local person: Person = { player = player, fixed = false,
				identity = { session = player.session_id, player = player.player_id, name = "" } }
			describe(person)
			people[player.session_id] = person
			count += 1
		end,
		removed = function(player: types.Player)
			if not people[player.session_id] then return end
			people[player.session_id] = nil
			count -= 1
		end,
		receive = function(player: types.Player, kind: unknown, a: unknown): boolean
			if kind ~= Net.LOOK then return false end
			local person, outfit = people[player.session_id], Net.outfit(a)
			if person and outfit and not person.fixed then
				local identity = table.clone(person.identity)
				identity.outfit = outfit
				person.identity = identity
			end
			return true
		end,
		metadataChanged = function(player: types.Player)
			local person = people[player.session_id]
			if person then describe(person) end
		end,
		setLook = function(player: types.Player, look: Shop.Look)
			local person = people[player.session_id]
			if not person then return end
			local identity = table.clone(person.identity)
			identity.look = if Shop.plain(look) then nil else table.clone(look)
			person.identity = identity
		end,
		identity = function(session: number): Net.Identity?
			local person = people[session]
			return if person then person.identity else nil
		end,
		name = function(session: number): string?
			local person = people[session]
			return if person then person.identity.name else nil
		end,
		all = function(): {[number]: types.Player}
			local out: {[number]: types.Player} = {}
			for session, person in people do out[session] = person.player end
			return out
		end,
		count = function(): number return count end,
	}
end

return table.freeze(People)
