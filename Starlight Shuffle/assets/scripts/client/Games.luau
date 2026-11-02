--!strict
--@client
-- Each mini-game's client module, by its shared/Games id. Literal requires,
-- so the build ships every mini-game's HUD with the client.
local Minigame = require("./Minigame")

local modules: {[string]: Minigame.Module} = {
	star_pass = require("../minigames/star_pass/Client"),
	pillow_fight = require("../minigames/pillow_fight/Client"),
	starcatchers = require("../minigames/starcatchers/Client"),
	lucky_shot = require("../minigames/lucky_shot/Client"),
	blast_mining = require("../minigames/blast_mining/Client"),
	head_to_head = require("../minigames/head_to_head/Client"),
}

return table.freeze(modules)
