--!strict
--@server
-- Each mini-game's server module, by its shared/Games id. Literal requires,
-- so the build ships every mini-game's rules with the server.
local Minigame = require("./Minigame")

local modules: {[string]: Minigame.Module} = {
	lucky_shot = require("../minigames/lucky_shot/Server"),
	blast_mining = require("../minigames/blast_mining/Server"),
	head_to_head = require("../minigames/head_to_head/Server"),
	minigame_1 = require("../minigames/minigame_1/Server"),
	minigame_2 = require("../minigames/minigame_2/Server"),
	minigame_3 = require("../minigames/minigame_3/Server"),
}

return table.freeze(modules)
