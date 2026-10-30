--!strict
--@client
local engine = require("@moonbase/engine")
local async = require("@dart/async")
local Player = require("./PlayerController")
local FollowCamera = require("./FollowCamera")
local SpatialQueries = require("./SpatialQueries")
local Controls = {}
Controls.__index = Controls

type Pointer = { x: number, y: number, startX: number, startY: number, moved: boolean }
export type Joystick = { x: number, y: number, dx: number, dy: number }
type Fields = {
	scene: engine.Scene?, player: Player.Controller?, playerEntity: engine.Entity?, rig: FollowCamera.Controller?,
	width: number, height: number, pointers: {[number]: Pointer}, mode: string,
	pinchDistance: number, pinchX: number, startZoom: number, startYaw: number,
	-- The on-screen joystick, and whether its thumb moved since it was last
	-- drawn (it redraws in the next tick: see showJoystick).
	joystick: Joystick?, joystickMoved: boolean, onJoystickChanged: (() -> ())?, disposed: boolean,
	spatial: SpatialQueries.Controller?, spatialLabel: SpatialQueries.Label?, onLabelChanged: (() -> ())?,
	showSpatial: boolean,
	-- Logical pixels covered at the bottom of the view; the camera looks past them.
	obscured: number,
	-- Consulted on a plain tap before walking; returning true consumes it
	-- (client/Props pokes the prop under the finger instead).
	onTap: ((x: number, y: number) -> boolean)?,
	-- A finger landing in the view (not the joystick strip) is a press until
	-- it moves, a second finger lands or it lifts: onPress hears it land
	-- (client/Holds may start holding the player under it) and onPressEnd how
	-- it ended, `lifted` false when it turned into a drag or pinch. Returning
	-- true from onPressEnd consumes the tap.
	onPress: ((x: number, y: number) -> ())?,
	onPressEnd: ((lifted: boolean) -> boolean)?,
	pressing: boolean,
	-- Consulted as a first finger lands; returning true takes the whole touch,
	-- which then neither walks, presses nor steers (a tap that only closes the
	-- chat's keyboard, as phones do).
	captureTap: (() -> boolean)?,
	-- Consulted as a first finger lands: how much of the view's bottom the HUD
	-- covers (the chat bar and what is open above it). The joystick strip is
	-- the bottom third of the rest.
	covered: (() -> number)?,
	-- Trigger colliders the player currently stands in, by collider id, and
	-- the subscriptions that maintain it. The UI reads `nearby` to show a
	-- prompt; for now each change is printed.
	nearby: {[string]: engine.ColliderComponent}, sensing: {async.StreamSubscription<engine.ColliderComponent>},
}
export type Controller = typeof(setmetatable({} :: Fields, Controls))

function Controls.new(): Controller
	return setmetatable({
		scene = nil, player = nil, playerEntity = nil, rig = nil, width = 1, height = 1,
		pointers = {}, mode = "none", pinchDistance = 1, pinchX = 0, startZoom = 0.7, startYaw = 0,
		joystick = nil, joystickMoved = false, onJoystickChanged = nil, disposed = false,
		spatial = nil, spatialLabel = nil, onLabelChanged = nil,
		showSpatial = true, onTap = nil, onPress = nil, onPressEnd = nil, pressing = false, captureTap = nil, covered = nil, obscured = 0,
		nearby = {}, sensing = {},
	} :: Fields, Controls)
end

-- Listens to the player's collider. Overlaps with Interactable triggers
-- (racks, the mirror, the vanity) enter and leave `nearby`.
function Controls.sense(self: Controller, entity: engine.Entity)
	local sensor = entity.collider
	if not sensor then return end
	table.insert(self.sensing, sensor.entered:listen({
		onData = function(other: engine.ColliderComponent)
			if self.disposed or not other.isValid then return end
			if other.layer ~= "Interactable" then return end
			self.nearby[other.id] = other
			print("Near " .. other.owner.name)
		end,
	}))
	table.insert(self.sensing, sensor.exited:listen({
		onData = function(other: engine.ColliderComponent)
			if self.disposed then return end
			-- Scene teardown can deliver exits after the collider was invalidated.
			if not other.isValid then
				for id, collider in self.nearby do
					if not collider.isValid then self.nearby[id] = nil end
				end
				return
			end
			if not self.nearby[other.id] then return end
			self.nearby[other.id] = nil
			print("Left " .. other.owner.name)
		end,
	}))
end

function Controls.stopSensing(self: Controller)
	for _, subscription in self.sensing do subscription:cancel() end
	table.clear(self.sensing)
	table.clear(self.nearby)
end

-- The joystick appears and disappears at once. A thumb that only moved
-- redraws in the next tick (update), with the frame the game draws for it: a
-- finger moves many times a frame on a phone the game outpaces, and each
-- redraw of its own would cost Flutter a whole frame.
function Controls.showJoystick(self: Controller, joystick: Joystick?)
	local appeared = (joystick == nil) ~= (self.joystick == nil)
	self.joystick = joystick
	self.joystickMoved = not appeared and joystick ~= nil
	if appeared and self.onJoystickChanged then self.onJoystickChanged() end
end

-- Ends the press under way, if any; true when its end consumes the tap.
function Controls.endPress(self: Controller, lifted: boolean): boolean
	if not self.pressing then return false end
	self.pressing = false
	return if self.onPressEnd then self.onPressEnd(lifted) else false
end

function Controls.resetInput(self: Controller)
	self:endPress(false)
	table.clear(self.pointers)
	self.mode = "none"
	if self.player then self.player:stop() end
	if self.rig then self.rig.panVelocity, self.rig.panDelta = vector.zero, vector.zero end
	self:showJoystick(nil)
end

function Controls.attachScene(self: Controller, scene: engine.Scene?)
	self:setFocus(false)
	self:resetInput()
	self:stopSensing()
	self.scene, self.player, self.playerEntity, self.rig = scene, nil, nil, nil
	self.spatial = nil
	self:updateLabel()
	-- Players are spawned, so they arrive later through setPlayer.
end

-- The local player's avatar. Roster changes may hand control to another one.
function Controls.setPlayer(self: Controller, entity: engine.Entity, player: Player.Controller?)
    self:resetInput(); self:stopSensing()
    self.player,self.playerEntity=player,entity
    local scene=self.scene
    if not scene then return end
    self.spatial=SpatialQueries.new(scene,entity)
    self:sense(entity)
    local camera=scene.activeCamera
    if not self.rig and camera then
        -- The follow camera starts on the first player the scene receives.
        local rig=FollowCamera.new(camera,entity.transform.worldPosition,self.width,self.height)
        self.rig=rig
        rig:update(0,entity.transform.worldPosition,vector.zero,false,false,false)
    end
    if self.rig then self:setFocus(self.rig.focused) end
end

function Controls.setFocus(self: Controller, focused: boolean, frame: FollowCamera.FocusFrame?)
	local rig = self.rig
	if not rig or not rig.camera.isValid then return end
	rig:setFocus(focused, frame)
	-- Only the wardrobe dissolves scenery between the camera and the avatar.
	rig.camera.fadeSubject = if focused and self.player then self.playerEntity else nil
end

-- The player has arrived somewhere: the view glides in to them.
function Controls.glideIn(self: Controller)
	if self.rig then self.rig:glideIn() end
end

function Controls.resize(self: Controller, width: number, height: number)
	self.width, self.height = math.max(1, width), math.max(1, height)
	if self.rig then self.rig:resize(self.width, self.height) end
end

function Controls.setObscured(self: Controller, bottom: number)
	self.obscured = bottom
end

function Controls.pair(self: Controller): (Pointer?, Pointer?)
	local first: Pointer? = nil
	for _, pointer in self.pointers do
		if first then return first, pointer end
		first = pointer
	end
	return first, nil
end

function Controls.pointerDown(self: Controller, id: number, x: number, y: number, secondary: boolean)
	if not self.player or self.disposed then return end
	-- An untracked pointer's moves and lift are ignored.
	if next(self.pointers) == nil and self.captureTap and self.captureTap() then return end
	self.pointers[id] = { x = x, y = y, startX = x, startY = y, moved = false }
	local a, b = self:pair()
	local rig: FollowCamera.Controller? = self.rig
	if a and b then
		self:endPress(false)
		self.player:stop()
		self:showJoystick(nil)
		self.mode = "pinch"
		self.pinchDistance = math.max(1, math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2))
		self.pinchX = (a.x + b.x) / 2
		if rig then self.startZoom, self.startYaw = rig.zoomTarget, rig.yawTarget end
	else
		local visible = self.height - (if self.covered then self.covered() else 0)
		self.mode = if secondary then "orbit" elseif y > visible * 2 / 3 then "joy" else "tap"
		if self.mode == "joy" then self.player:stop() end
		if secondary and rig then self.startYaw = rig.yawTarget end
		if self.mode == "tap" then
			self.pressing = true
			if self.onPress then self.onPress(x, y) end
		end
	end
end

function Controls.pinch(self: Controller, ratio: number, dx: number)
	local rig: FollowCamera.Controller? = self.rig
	if not rig then return end
	if math.abs(ratio - 1) > 0.04 then rig:setZoom(self.startZoom * (ratio - math.sign(ratio - 1) * 0.04)) end
	if math.abs(dx) > 6 then rig:setYaw(self.startYaw - (dx - math.sign(dx) * 6) / self.width * 2.6) end
end

function Controls.pointerMove(self: Controller, id: number, x: number, y: number)
	local pointer = self.pointers[id]
	if not pointer then return end
	local dx, dy = x - pointer.x, y - pointer.y
	pointer.x, pointer.y = x, y
	local fromX, fromY = x - pointer.startX, y - pointer.startY
	local magnitude = math.sqrt(fromX * fromX + fromY * fromY)
	if magnitude > 8 then pointer.moved = true end
	local rig: FollowCamera.Controller? = self.rig
	if self.mode == "pinch" then
		local a, b = self:pair()
		if a and b then self:pinch(math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2) / self.pinchDistance, (a.x + b.x) / 2 - self.pinchX) end
	elseif self.mode == "joy" then
		if self.player then self.player:joystick(fromX, fromY) end
		if magnitude > 14 or self.joystick then
			local scale = math.min(1, 56 / math.max(1, magnitude))
			self:showJoystick({ x = pointer.startX, y = pointer.startY, dx = fromX * scale, dy = fromY * scale })
		end
	elseif self.mode == "orbit" and rig then
		rig:setYaw(self.startYaw - fromX / self.width * 2.6)
	elseif self.mode == "tap" or self.mode == "pan" then
		if pointer.moved then
			self.mode = "pan"
			self:endPress(false)
		end
		if self.mode == "pan" and rig then rig:pan(dx, dy) end
	end
end

function Controls.pointerUp(self: Controller, id: number, cancelled: boolean)
	local pointer = self.pointers[id]
	if not pointer then return end
	local mode, player, rig = self.mode, self.player, self.rig
	self.pointers[id] = nil
	if mode == "joy" then
		if player then player:stop() end
		self:showJoystick(nil)
	end
	-- A press that ran its course (a player's profile opened) is not a tap.
	local held = self:endPress(not cancelled and not pointer.moved)
	if not held and not cancelled and not pointer.moved and (mode == "tap" or mode == "joy") and player and rig
		and not (self.onTap and self.onTap(pointer.x, pointer.y)) then
		if self.spatial then self.spatial:selectTrigger(pointer.x, pointer.y) end
		local destination = rig:groundPoint(pointer.x, pointer.y, player.transform.worldPosition.y)
		if destination then player:walkTo(destination) end
	end
	-- Lifting one pinch finger never turns the remaining finger into a drag/tap.
	self.mode = if next(self.pointers) then "done" else "none"
end

function Controls.scroll(self: Controller, dy: number)
	if self.rig and dy ~= 0 then self.rig:setZoom(self.rig.zoomTarget * (if dy < 0 then 1.08 else 0.93)) end
end

function Controls.trackpadStart(self: Controller)
	self:resetInput()
	self.mode = "trackpad"
	if self.rig then self.startZoom, self.startYaw = self.rig.zoomTarget, self.rig.yawTarget end
end

function Controls.trackpadUpdate(self: Controller, scale: number, panX: number)
	if self.mode == "trackpad" then self:pinch(scale, panX) end
end

function Controls.trackpadEnd(self: Controller)
	self.mode = "none"
end

function Controls.update(self: Controller, dt: number)
	if self.joystickMoved then
		self.joystickMoved = false
		if self.onJoystickChanged then self.onJoystickChanged() end
	end
	local scene, player = self.scene, self.player
	if self.disposed or not scene or not scene.isValid or not player or not player.transform.isValid then return end
	dt = math.clamp(dt, 0, 0.1)
	local camera = scene.activeCamera
	local rig: FollowCamera.Controller? = self.rig
	if camera and (not rig or rig.camera.id ~= camera.id) then
		local previous = rig
		if previous and previous.camera.isValid then previous.camera.fadeSubject = nil end
		rig = FollowCamera.new(camera, player.transform.worldPosition, self.width, self.height)
		self.rig = rig
		self:setFocus(if previous then previous.focused else false, if previous then previous.focusFrameTarget else nil)
		if previous then rig:setFocusProgress(previous.focusProgress) end
	elseif not camera then
		if rig and rig.camera.isValid then rig.camera.fadeSubject = nil end
		rig, self.rig = nil, nil
	end
	player:update(dt, if rig then rig.yaw else 0, if rig then rig.camera.transform.worldPosition else nil)
	if rig then
		local bounds=if player.renderer then player.renderer.contentBounds else nil
		local height=if bounds then (bounds.max.y-bounds.min.y)*math.abs(player.baseScale.y) else 1.8
		rig:setObscured(self.obscured)
		rig:update(dt, player.transform.worldPosition, player.leadVelocity, player.walking, self.mode == "pan", self.mode == "pinch" or self.mode == "orbit" or self.mode == "trackpad",height)
	end
	self:updateLabel()
end

function Controls.updateLabel(self: Controller)
	local nextLabel = if self.spatial and self.showSpatial then self.spatial:label() else nil
	local previous = self.spatialLabel
	if previous == nil and nextLabel == nil then return end
	if previous and nextLabel and previous.x == nextLabel.x and previous.y == nextLabel.y and previous.text == nextLabel.text then return end
	self.spatialLabel = nextLabel
	if self.onLabelChanged then self.onLabelChanged() end
end

function Controls.dispose(self: Controller)
	self.disposed = true
	self:attachScene(nil)
	self.onJoystickChanged = nil
	self.onLabelChanged = nil
	self.onTap, self.onPress, self.onPressEnd, self.captureTap, self.covered = nil, nil, nil, nil, nil
end

return Controls
