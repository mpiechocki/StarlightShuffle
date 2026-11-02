--!strict
--@server
-- Each mini-game's server module, by its shared/Games id. Literal requires,
-- so the build ships every mini-game's rules with the server.
local Minigame = require("./Minigame")

local modules: {[string]: Minigame.Module} = {
	star_pass = require("../minigames/star_pass/Server"),
	pillow_fight = require("../minigames/pillow_fight/Server"),
	lucky_shot = require("../minigames/lucky_shot/Server"),
	blast_mining = require("../minigames/blast_mining/Server"),
	head_to_head = require("../minigames/head_to_head/Server"),
}

return table.freeze(modules)
