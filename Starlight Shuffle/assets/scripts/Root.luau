--!strict
--@client
-- Client root. The server picks the scene (the lobby, or the cycle's current
-- mini-game) and replicates everyone's avatar (client/Multiplayer); the player
-- walks theirs with the movement controls and follow camera ported from Sky
-- Lounge, wearing their own outfit. client/Place knows which place this is
-- and drives the HUD (widgets/Hud): in the lobby, tapping the big gold button
-- on the wall starts the mini-game cycle and the blue one opens the
-- leaderboard; in the cycle, the HUD's head shows the mini-game and its
-- Pause/Play button. Moving between places keeps this VM: everything that
-- belonged to the previous server instance resets. The app's loading screen
-- stays up until we stand dressed in the first scene.
local engine = require("@moonbase/engine")
local game = require("@moonbase/game")
local runtime = require("@flutter_luau/runtime")
local session = require("@es/session")
local w = require("@flutter/widgets")
local Net = require("./shared/Net")
local Controls = require("./gameplay/Controls")
local Avatars = require("./gameplay/Avatars")
local Multiplayer = require("./client/Multiplayer")
local Appearance = require("./client/Appearance")
local Place = require("./client/Place")
local WalkControls = require("./widgets/WalkControls")
local Hud = require("./widgets/Hud")
local WallLabels = require("./widgets/WallLabels")

--@property
local title: string = "Starlight Shuffle"

-- The lobby's wall buttons, by the authored ids a tap may hit.
local START_IDS = { ["start-button"] = true, ["start-frame"] = true, ["start-stars"] = true }
local BOARD_IDS = { ["leaderboard-button"] = true, ["leaderboard-frame"] = true }

local controls: Controls.Controller? = nil
local multiplayer: Multiplayer.Controller? = nil
local place: Place.Controller? = nil
local labels: WallLabels.Labels? = nil
-- Lifts the app's loading screen (game.holdLoadingScreen).
local releaseLoading = function() end

-- What the signed-in player is wearing; the starter look for an account with none.
local function wornOutfit(): {number}
	return Net.outfit(session.user.outfit) or table.clone(Appearance.STARTER)
end

-- The authored id of what is under (x, y), looking past avatars; nil for nothing.
local function tapped(walker: Controls.Controller, x: number, y: number): string?
	local scene = walker.scene
	if not scene or not scene.isValid then return nil end
	local viewport, camera = scene.viewport, scene.activeCamera
	if not viewport or not camera then return nil end
	local player = walker.playerEntity
	local hit = Avatars.pickPast(scene, camera, viewport, x, y, if player and player.isValid then {player} else {})
	return if hit then hit.entity.id else nil
end

return engine.defineScript({
	onStart = function()
		local walker = Controls.new()
		walker.showSpatial = false
		controls = walker
		local here = Place.new()
		place = here
		local tags = WallLabels.new()
		labels = tags
		-- Our own thumbnail comes from the session until our identity carries one.
		local others = Multiplayer.new(walker, wornOutfit(), Net.avatarId(session.user.avatar_id))
		multiplayer = others
		releaseLoading = game.holdLoadingScreen()
		others.onScene = function(scene: engine.Scene?)
			walker:attachScene(scene)
			here:setScene(scene)
			if scene then print(title .. ": " .. scene.name .. " ready") end
		end
		others.onReady = function() releaseLoading() end
		others.onArrive = function(avatar: Multiplayer.Avatar)
			if avatar.mine then walker:glideIn() end
		end
		-- Another server instance: its own world, round and leaderboard.
		here.onTransferred = function()
			others:transferred()
			walker:attachScene(walker.scene)
		end
		walker.onTap = function(x: number, y: number): boolean
			if here.place == "cycle" then return here:tap(x, y) end
			if here.place ~= "lobby" then return false end
			local id = tapped(walker, x, y)
			if id and START_IDS[id] then here:start(); return true end
			if id and BOARD_IDS[id] then here:openBoard(true); return true end
			return false
		end
		runtime.runView(w.Stack({fit = w.StackFit.expand, children = {
			WalkControls(walker),
			WallLabels.View({labels = tags}),
			Hud({place = here}),
		}}))
	end,
	onUpdate = function(dt: number)
		if multiplayer then multiplayer:tick() end
		if controls then controls:update(dt) end
		if multiplayer then multiplayer:update(dt) end
		if place then place:update(dt) end
		if controls and place then controls.fixedCamera = place:fixedCamera() end
		if labels and controls and place then
			labels:update(if place.place == "lobby" then controls.scene else nil)
		end
	end,
	onDestroy = function()
		releaseLoading()
		if place then place:dispose(); place = nil end
		if multiplayer then multiplayer:dispose(); multiplayer = nil end
		if controls then controls:dispose(); controls = nil end
		labels = nil
	end,
})
