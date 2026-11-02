--!strict
--@server
-- Who may run the experience's admin tools: the account ids listed under
-- `admins` in the server's startup settings (project.json `server.startup`,
-- editable in the editor's project settings), for now the experience's world
-- testers. The platform does not tell game scripts who its testers are, so
-- the list is kept here by hand. Anything that is not a whole account id is
-- ignored; with no list, nobody is an admin.
local types = require("@moonbase/types")

export type Admins = { is: (player: types.Player) -> boolean }

local Admins = {}

-- The admin account ids in [startup] (the startup settings' value).
function Admins.ids(startup: unknown): {[number]: boolean}
	local ids: {[number]: boolean} = {}
	local settings = if type(startup) == "table" then (startup :: {[unknown]: unknown}) else nil
	local list = if settings then settings.admins else nil
	if type(list) == "table" then
		for _, id in list :: {[unknown]: unknown} do
			if type(id) == "number" and id == math.floor(id) and id >= 0 then ids[id] = true end
		end
	end
	return ids
end

function Admins.new(startup: unknown): Admins
	local ids = Admins.ids(startup)
	return {
		is = function(player: types.Player): boolean
			return ids[player.player_id] == true
		end,
	}
end

return table.freeze(Admins)
