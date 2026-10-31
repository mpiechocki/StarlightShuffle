--!strict
--@client
-- Each mini-game's client module, by its shared/Games id. Literal requires,
-- so the build ships every mini-game's HUD with the client.
local Minigame = require("./Minigame")

local modules: {[string]: Minigame.Module} = {
	star_pass = require("../minigames/star_pass/Client"),
	lucky_shot = require("../minigames/lucky_shot/Client"),
	blast_mining = require("../minigames/blast_mining/Client"),
	head_to_head = require("../minigames/head_to_head/Client"),
	minigame_1 = require("../minigames/minigame_1/Client"),
	minigame_2 = require("../minigames/minigame_2/Client"),
	minigame_3 = require("../minigames/minigame_3/Client"),
}

return table.freeze(modules)
