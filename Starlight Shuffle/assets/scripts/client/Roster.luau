--!strict
--@client
-- Who is in this place as this player sees them: everyone whose avatar is
-- replicated here (a blocked pair never is), yourself first, then by name.
-- client/Multiplayer keeps it up to date.
export type Member = { session: number, player: number, name: string, avatar: string?, mine: boolean }
type Fields = { members: {Member}, listeners: {() -> ()} }
local Roster = {}
Roster.__index = Roster
export type Roster = typeof(setmetatable({} :: Fields, Roster))

-- Local Play's test players have synthetic ids from here up, and no profile.
Roster.TEST_IDS = 2 ^ 52

function Roster.new(): Roster
	return setmetatable({ members = {}, listeners = {} } :: Fields, Roster)
end

local function before(a: Member, b: Member): boolean
	if a.mine ~= b.mine then return a.mine end
	local x, y = string.lower(a.name), string.lower(b.name)
	if x ~= y then return x < y end
	return a.session < b.session
end

local function same(a: {Member}, b: {Member}): boolean
	if #a ~= #b then return false end
	for i, x in a do
		local y = b[i]
		if x.session ~= y.session or x.player ~= y.player or x.name ~= y.name or x.avatar ~= y.avatar
			or x.mine ~= y.mine then return false end
	end
	return true
end

-- Replaces everyone; listeners hear only about a real change.
function Roster.set(self: Roster, members: {Member})
	local sorted = table.clone(members)
	table.sort(sorted, before)
	if same(sorted, self.members) then return end
	self.members = sorted
	for _, listener in table.clone(self.listeners) do listener() end
end

-- Calls [listener] after every change; returns its removal.
function Roster.listen(self: Roster, listener: () -> ()): () -> ()
	table.insert(self.listeners, listener)
	return function()
		local at = table.find(self.listeners, listener)
		if at then table.remove(self.listeners, at) end
	end
end

-- Whether [member] has an Everskies profile to open: not yourself, and not
-- one of local Play's test players.
function Roster.linkable(member: {read player: number, read mine: boolean}): boolean
	return not member.mine and member.player > 0 and member.player < Roster.TEST_IDS
end

-- The app path of [member]'s profile.
function Roster.profile(member: {read player: number}): string
	return "/user/" .. string.format("%d", member.player)
end

-- The app path that reports chat message [id] in [experience], said by
-- [player] as [name]. The app decodes the whole path before reading it, so
-- every byte of the name but letters and digits is percent-encoded.
function Roster.chatReport(experience: string, id: string, player: number, name: string): string
	local encoded = string.gsub(name, "[^%w]", function(c: string): string return string.format("%%%02X", string.byte(c)) end)
	return string.format("/report/game-chat/%s/%s/%d?name=%s", experience, id, player, encoded)
end

return Roster
