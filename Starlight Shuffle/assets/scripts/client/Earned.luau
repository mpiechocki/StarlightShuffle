--!strict
--@client
-- What the current mini-game won you, once its prizes are given (the cycle's
-- EARNED, boosters included): set by client/Place, cleared as a mini-game
-- opens, shown on every mini-game's results (GameUi.earned).
local foundation = require("@flutter/foundation")

local Earned = {}

-- The mini-game's id and the Starlights it won you, or nil before they are given.
Earned.latest = nil :: { game: string, starlights: number }?
Earned.changed = foundation.ChangeNotifier()

function Earned.set(game: string, starlights: number)
	Earned.latest = { game = game, starlights = starlights }
	Earned.changed:notifyListeners()
end

function Earned.clear()
	if Earned.latest == nil then return end
	Earned.latest = nil
	Earned.changed:notifyListeners()
end

return Earned
