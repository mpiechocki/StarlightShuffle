--!strict
--@client
-- Client root. The server picks the scene (the lobby, or the cycle's current
-- mini-game) and replicates everyone's avatar (client/Multiplayer); the player
-- walks theirs with the movement controls and follow camera ported from Sky
-- Lounge, wearing their own outfit. client/Place knows which place this is
-- and drives the HUD (widgets/Hud): in the lobby, tapping the arcade (its
-- doorway, the room behind it or a cabinet) starts the mini-game cycle and the
-- leaderboard board on the wall opens the leaderboard; in the cycle, the HUD's head shows the mini-game and its
-- Pause/Play button. The lobby has a chat as in Sky Lounge (client/Chat,
-- widgets/LobbyChat), and the shop stall opens the shop (client/Shop,
-- widgets/ShopPanel), whose looks show on everyone's name tag and avatar. Moving between places keeps this VM: everything that
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
local Chat = require("./client/Chat")
local WalkControls = require("./widgets/WalkControls")
local Hud = require("./widgets/Hud")
local WallLabels = require("./widgets/WallLabels")
local LobbyChat = require("./widgets/LobbyChat")
local Shop = require("./client/Shop")
local ShopPanel = require("./widgets/ShopPanel")
local Looks = require("./client/Looks")

--@property
local title: string = "Starlight Shuffle"

-- The lobby's tap targets, by the prefix of the authored ids a tap may hit:
-- the arcade (start-…), the leaderboard (leaderboard-…) and the shop stall (shop, shop-…).
local function starts(id: string): boolean return string.sub(id, 1, 6) == "start-" end
local function opensBoard(id: string): boolean return string.sub(id, 1, 12) == "leaderboard-" end
local function opensShop(id: string): boolean return id == "shop" or string.sub(id, 1, 5) == "shop-" end

local controls: Controls.Controller? = nil
local multiplayer: Multiplayer.Controller? = nil
local place: Place.Controller? = nil
local chat: Chat.Controller? = nil
local shop: Shop.Controller? = nil
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
		local talk = Chat.new(walker, others)
		chat = talk
		local store = Shop.new()
		shop = store
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
		others.onLeft = function(id: number) talk:left(id) end
		-- Another server instance: its own world, round, leaderboard and chat.
		here.onTransferred = function()
			others:transferred()
			talk:reset()
			store:transferred()
			walker:attachScene(walker.scene)
		end
		-- A tap on the game while typing only ends the typing; the joystick
		-- strip stays above the chat bar.
		walker.captureTap = function(): boolean
			local dismiss = talk.dismissInput
			return dismiss ~= nil and dismiss()
		end
		walker.covered = function(): number
			local covered = talk.covered
			return if covered then covered() else 0
		end
		walker.onTap = function(x: number, y: number): boolean
			if here.place == "cycle" then return here:tap(x, y) end
			if here.place ~= "lobby" then return false end
			local id = tapped(walker, x, y)
			if id and starts(id) then here:start(); return true end
			if id and opensBoard(id) then here:openBoard(true); return true end
			if id and opensShop(id) then
				local me = others.me
				store:openShop(others:wearing(), if me then me.name else nil)
				return true
			end
			return false
		end
		runtime.runView(w.Stack({fit = w.StackFit.expand, children = {
			WalkControls(walker),
			WallLabels.View({labels = tags}),
			LobbyChat({place = here, chat = talk, layer = "under"}),
			Hud({place = here}),
			LobbyChat({place = here, chat = talk, layer = "over"}),
			ShopPanel({shop = store, clock = function(): number return store.time end}),
		}}))
	end,
	onUpdate = function(dt: number)
		if multiplayer then multiplayer:tick() end
		if controls then controls:update(dt) end
		if multiplayer then multiplayer:update(dt) end
		if place then place:update(dt) end
		if shop then
			shop:update(dt)
			-- The viewer's look settings, and in a mini-game only styled name tags.
			local prefs = shop:prefs()
			if multiplayer then multiplayer.reduceEffects = prefs.effects end
			Looks.setStill(prefs.motion)
			Looks.tick(dt)
			if chat then
				chat.stillLooks = prefs.motion
				chat.cosmeticOnly = place ~= nil and place.place == "cycle"
			end
		end
		if chat then chat:update(dt) end
		if controls and place then controls.fixedCamera = place:fixedCamera() end
		if labels and controls and place then
			labels:update(if place.place == "lobby" then controls.scene else nil)
		end
	end,
	onDestroy = function()
		releaseLoading()
		if chat then chat:dispose(); chat = nil end
		if shop then shop:dispose(); shop = nil end
		if place then place:dispose(); place = nil end
		if multiplayer then multiplayer:dispose(); multiplayer = nil end
		if controls then controls:dispose(); controls = nil end
		labels = nil
	end,
})
