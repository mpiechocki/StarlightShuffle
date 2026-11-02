--!strict
--@server
-- The admins' lineup: which mini-games every cycle plays (shared/Games ids),
-- kept in @moonbase/storage so a change reaches every lobby and cycle and
-- outlasts them. Nothing stored means every mini-game.
--
-- An admin (server/Admins) changes it with LINEUP from either place; this
-- place takes the change at once, and others read the store again before they
-- pick their next mini-game (`refresh`). Admins here hear ADMIN with the
-- lineup on arrival, after a change and whenever `notify` is called (a cycle
-- moving on), with what is on now and up next.
local server = require("@moonbase/server")
local storage = require("@moonbase/storage")
local Net = require("../shared/Net")
local Games = require("../shared/Games")
local Admins = require("./Admins")

export type Lineup = {
	-- The included mini-game ids, in Games order (never empty).
	included: () -> {string},
	-- Reads the store again (then calls [done], if any).
	refresh: (done: (() -> ())?) -> (),
	added: (player: server.Player) -> (),
	removed: (player: server.Player) -> (),
	receive: (player: server.Player, kind: unknown, ...unknown) -> boolean,
	-- Tells this place's admins the lineup again.
	notify: () -> (),
}
-- What this place is playing: the current mini-game and the next (cycles only).
export type Status = () -> (string?, string?)

-- These bodies run on the datastore (Lua 5.1, store commands only).
local readOperation = storage.define({
	name = "lineup_read",
	run = function(store: storage.Store, _context: storage.Context, _args: {}): string?
		return store.GET(store.key("lineup"))
	end,
})

local writeOperation = storage.define({
	name = "lineup_write",
	run = function(store: storage.Store, _context: storage.Context, args: {ids: string}): boolean
		store.SET(store.key("lineup"), args.ids)
		return true
	end,
})

local MAX_IDS = 64

local Lineup = {}

-- The ids in a stored lineup ("id,id,…"); nil for nothing stored.
function Lineup.parse(stored: unknown): {string}?
	if type(stored) ~= "string" or stored == "" then return nil end
	local ids: {string} = {}
	for id in string.gmatch(stored, "[^,]+") do
		if #ids < MAX_IDS then table.insert(ids, id) end
	end
	return ids
end

function Lineup.new(admins: Admins.Admins, status: Status): Lineup
	local included = Games.included(nil)
	local here: {[number]: server.Player} = {} -- admins in this place, by session

	local function lineupFor(): Net.Lineup
		local current, upNext = status()
		return { included = included, current = current, upNext = upNext }
	end

	local function notify()
		local value = Net.lineupValue(lineupFor())
		for _, player in here do
			if player.isActive then server.notifyPlayers({player}, Net.ADMIN, value) end
		end
	end

	local function refresh(done: (() -> ())?)
		readOperation:call({}, function(result)
			if result.ok then
				local ids = Lineup.parse(result.value)
				local next = Games.included(ids)
				local changed = table.concat(next, ",") ~= table.concat(included, ",")
				included = next
				if changed then notify() end
			else
				print("Lineup read failed: " .. result.error.message)
			end
			if done then done() end
		end)
	end

	return {
		included = function(): {string} return included end,
		refresh = refresh,
		added = function(player: server.Player)
			if not admins.is(player) then return end
			here[player.session_id] = player
			server.notifyPlayers({player}, Net.ADMIN, Net.lineupValue(lineupFor()))
		end,
		removed = function(player: server.Player)
			here[player.session_id] = nil
		end,
		receive = function(player: server.Player, kind: unknown, ...: unknown): boolean
			if kind ~= Net.LINEUP then return false end
			-- Only admins; anyone else's request is dropped without a word.
			if not admins.is(player) then return true end
			local ids = Net.gameIds(..., MAX_IDS)
			if not ids then return true end
			local next = Games.included(ids)
			-- Every id unknown (or none): keep what there is.
			local known = 0
			for _, id in ids do if Games.get(id) then known += 1 end end
			if known == 0 then notify(); return true end
			included = next
			notify()
			writeOperation:call({ids = table.concat(next, ",")}, function(result)
				if not result.ok then print("Lineup write failed: " .. result.error.message) end
			end)
			return true
		end,
		notify = notify,
	}
end

return table.freeze(Lineup)
