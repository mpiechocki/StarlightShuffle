--!strict
--@client
local engine = require("@moonbase/engine")
local WardrobeTransition = require("../client/WardrobeTransition")
local Rig = {}
Rig.__index = Rig
local MAX_YAW = math.pi / 6 -- 30° either way of straight on
local FOCUS_HEIGHT = 1.35 -- Metres above the player's feet; aim near the neck.
local DEFAULT_ZOOM = .5
-- How far out and in the player may zoom; the camera's distance is its
-- lens's over the zoom.
local MIN_ZOOM = .3
local MAX_ZOOM = 2.2
-- An arrival's glide (see glideIn): it starts this much further out and
-- turned, and eases in more slowly than a pinch for this long.
local GLIDE_OUT = .78 -- of the zoom: about a quarter further out
local GLIDE_YAW = .12 -- about 7°
local GLIDE_SECONDS = 1.1
local GLIDE_RESPONSE = 2.6 -- 1/s, against 6 for zoom and 4 for yaw
local WARDROBE_TILT_UP = math.rad(3)
local ORTHO_ELEVATION = 0.35 -- About 19° down, against 10° for the perspective view.
local LIFT_RESPONSE = 8 -- 1/s; how quickly the view follows the keyboard
-- How far the scene rises, as a share of the covered height. Proportional,
-- so it eases out with the keyboard instead of stepping when it closes.
local LIFT_SHARE = 0.4
-- One view on every screen, whichever way it is turned: the camera stands
-- DISTANCE metres back (over the zoom), and its lens's focal length is FOCAL
-- pixels per pixel of the screen's short side. The avatar is then the same
-- share of the short side everywhere, at every zoom; a longer side only shows
-- more around it. A portrait phone sees about 50° up and down.
local DISTANCE = 2.85
local FOCAL = 2.32
export type FocusFrame = {ny: number, fill: number}

type Fields = {
	camera: engine.CameraComponent, width: number, height: number, viewport: engine.Viewport,
	x: number, z: number, focusY: number, yaw: number, yawTarget: number,
	zoom: number, zoomTarget: number, sway: number,
	panOffset: vector, panDelta: vector, panVelocity: vector,
	lastFocus: vector?,
	focused: boolean, focusBlend: number, focusProgress: number?,
	focusFrame: FocusFrame, focusFrameTarget: FocusFrame, baseOrthoHeight: number,
	-- Logical pixels covered at the bottom of the view, and how far (in pixels)
	-- the view currently tilts down to lift the player above them.
	obscured: number, lift: number,
	-- Seconds left of an arrival's glide.
	gliding: number,
}
export type Controller = typeof(setmetatable({} :: Fields, Rig))

-- The vertical field of view (degrees) that gives a [width] x [height] view
-- the lens's focal length.
local function fieldOfView(width: number, height: number): number
	return math.deg(2 * math.atan(height / 2 / (FOCAL * math.min(width, height))))
end

function Rig.new(camera: engine.CameraComponent, target: vector, width: number, height: number): Controller
	local self: Controller = setmetatable({
		camera = camera, width = width, height = height,
		viewport = engine.Viewport({width = width, height = height}),
		x = target.x, z = target.z, focusY = target.y + FOCUS_HEIGHT,
		yaw = 0, yawTarget = 0, zoom = DEFAULT_ZOOM, zoomTarget = DEFAULT_ZOOM, sway = 0,
		panOffset = vector.zero, panDelta = vector.zero, panVelocity = vector.zero, lastFocus = nil,
		focused = false, focusBlend = 0, focusProgress = nil,
		focusFrame = {ny=0,fill=.5}, focusFrameTarget = {ny=0,fill=.5}, baseOrthoHeight = camera.orthoHeight,
		obscured = 0, lift = 0, gliding = 0,
	} :: Fields, Rig)
	camera.fov = fieldOfView(width, height)
	camera.zoom = 1
	return self
end

function Rig.resize(self: Controller, width: number, height: number)
	self.camera.fov = fieldOfView(width, height)
	self.width, self.height = width, height
	self.viewport = engine.Viewport({width = width, height = height})
end

-- Something covers the bottom [bottom] logical pixels of the view (the
-- on-screen keyboard); 0 when nothing does.
function Rig.setObscured(self: Controller, bottom: number)
	self.obscured = math.max(0, bottom)
end

-- World units per screen pixel at [point]'s depth, from the current camera.
local function worldPerPixel(self: Controller, point: vector): number?
	local camera, viewport = self.camera, self.viewport
	local projected = camera:worldToViewport({point = point, viewport = viewport})
	if not projected or not projected.inFront then return nil end
	local x, y = viewport.width / 2, viewport.height / 2
	local a = camera:screenToWorld({x = x, y = y, viewDepth = projected.viewDepth, viewport = viewport})
	local b = camera:screenToWorld({x = x, y = y + 1, viewDepth = projected.viewDepth, viewport = viewport})
	return vector.magnitude(b - a)
end

function Rig.setZoom(self: Controller, zoom: number)
	self.zoomTarget = math.clamp(zoom, MIN_ZOOM, MAX_ZOOM)
end

-- The player has arrived: the view starts further out and turned a little,
-- and glides in to where it was.
function Rig.glideIn(self: Controller)
	self.zoom = math.max(MIN_ZOOM, self.zoomTarget * GLIDE_OUT)
	self.yaw = self.yawTarget + GLIDE_YAW
	self.gliding = GLIDE_SECONDS
end

function Rig.resetZoom(self: Controller)
	self:setZoom(DEFAULT_ZOOM)
end

-- Keep the walking rig intact beneath the dress-up fly-in so closing restores
-- its zoom, pan and neck-level focus. A sheet drag can scrub the blend directly.
function Rig.setFocus(self: Controller, on: boolean, frame: FocusFrame?)
	self.focused = on
	if frame then
		self.focusFrameTarget = {ny=frame.ny,fill=math.clamp(frame.fill,.2,.95)}
		if self.focusBlend < .001 then self.focusFrame = table.clone(self.focusFrameTarget) end
	end
end

function Rig.setFocusProgress(self: Controller, progress: number?)
	self.focusProgress = if progress then math.clamp(progress,0,1) else nil
	if self.focusProgress then self.focusBlend = self.focusProgress end
end

function Rig.setYaw(self: Controller, yaw: number)
	local over = math.abs(yaw) - MAX_YAW
	self.yawTarget = if over <= 0 then yaw else math.sign(yaw) * (MAX_YAW + 0.22 * over / (1 + 2 * over))
end

function Rig.pivot(self: Controller): vector
	return vector.create(self.x, self.focusY, self.z) + self.panOffset
end

function Rig.pan(self: Controller, dx: number, dy: number)
	local camera, viewport = self.camera, self.viewport
	local focus = camera:worldToViewport({point = self:pivot(), viewport = viewport})
	if not focus or not focus.inFront then return end
	local x, y = viewport.width / 2, viewport.height / 2
	local before = camera:screenToWorld({x = x, y = y, viewDepth = focus.viewDepth, viewport = viewport})
	local after = camera:screenToWorld({x = x + dx, y = y + dy, viewDepth = focus.viewDepth, viewport = viewport})
	local localDelta = camera.transform:worldVectorToLocal(before - after)
	-- Map screen-up motion onto camera-forward ground motion. Keep the existing
	-- depth sensitivity; projection handles lens zoom, aspect and parent scale.
	local worldDelta = camera.transform:localVectorToWorld(vector.create(localDelta.x, 0, -localDelta.y * 1.4))
	local delta = vector.create(worldDelta.x, 0, worldDelta.z)
	self.panOffset += delta
	self.panDelta += delta
end

function Rig.groundPoint(self: Controller, x: number, y: number, groundY: number): vector?
	local ray = self.camera:screenPointToRay({x = x, y = y, viewport = self.viewport})
	local hit = ray:intersectPlane({point = vector.create(0, groundY, 0), normal = vector.create(0, 1, 0)})
	return if hit then hit.position else nil
end

-- `velocity` only leads the follow point; pass the player's eased
-- `leadVelocity` so the lead ramps in and drifts out like the R&D doll's velX.
-- `walking` is whether the agent actually moved this frame: it recentres the
-- pan and cancels its glide, so it must not linger while the lead decays.
function Rig.update(self: Controller, dt: number, target: vector, velocity: vector, walking: boolean, panning: boolean, orbiting: boolean, avatarHeight: number?)
	if panning then
		self.panVelocity = vector.lerp(self.panVelocity, self.panDelta / math.max(dt, 0.001), math.min(1, dt * 20))
	elseif walking or orbiting then
		self.panVelocity = vector.zero
	else
		self.panOffset += self.panVelocity * dt
		self.panVelocity *= math.max(0, 1 - dt * 6)
		if vector.magnitude(self.panVelocity) < 0.01 then self.panVelocity = vector.zero end
	end
	self.panDelta = vector.zero
	local lead = math.clamp(velocity.x / 5.6, -1, 1)
	self.x += (target.x + lead - self.x) * math.min(1, dt * 3)
	self.z += (target.z - self.z) * math.min(1, dt * 2.2)
	-- Soft frame edge: follow faster when the player nears the screen's sides.
	local projected = self.camera:worldToViewport({point = target, viewport = self.viewport})
	if projected and projected.viewDepth > 0.01 then
		local ndcX = 2 * projected.x - 1
		local k = math.min(1, dt * math.max(0, math.abs(ndcX) - 0.45) * 30)
		self.x += (target.x + lead - self.x) * k
		self.z += (target.z - self.z) * k
	end
	if walking then self.panOffset *= math.max(0, 1 - dt * 2.5) end
	if not orbiting then self.yawTarget = math.clamp(self.yawTarget, -MAX_YAW, MAX_YAW) end
	local previous = self.yaw
	local gliding = self.gliding > 0
	self.gliding = math.max(0, self.gliding - dt)
	self.yaw += (self.yawTarget - self.yaw) * math.min(1, dt * (if orbiting then 12 elseif gliding then GLIDE_RESPONSE else 4))
	local sway = math.clamp((self.yaw - previous) / math.max(dt, 0.001) * 0.2, -0.32, 0.32)
	self.sway += (sway - self.sway) * math.min(1, dt * (if math.abs(sway) > math.abs(self.sway) then 8 else 1.4))
	self.zoom += (self.zoomTarget - self.zoom) * math.min(1, dt * (if gliding then GLIDE_RESPONSE else 6))
	local focus = self:pivot() + vector.create(math.cos(self.yaw), 0, -math.sin(self.yaw)) * self.sway
	local distance = DISTANCE / self.zoom
	-- An orthographic view has no perspective to show the floor, so it looks down more steeply.
	local elevation = if self.camera.projection == engine.CameraProjectionMode.orthographic then ORTHO_ELEVATION else 0.17
	local position = focus + vector.create(distance * math.sin(self.yaw), distance * elevation, distance * math.cos(self.yaw))
	local blendTarget = if self.focused then 1 else 0
	if self.focusProgress then self.focusBlend = self.focusProgress
	else
		-- Follow a moving target, including a released drag or mid-flight reversal.
		-- Around 96% there at 500ms, with the reference's gentle settling tail.
		self.focusBlend+=(blendTarget-self.focusBlend)*math.min(1,dt*WardrobeTransition.cameraResponse)
		if math.abs(blendTarget-self.focusBlend)<.0001 then self.focusBlend=blendTarget end
	end
	local frame, goal = self.focusFrame, self.focusFrameTarget
	local easing = math.min(1,dt*WardrobeTransition.frameResponse)
	frame.ny += (goal.ny-frame.ny)*easing
	frame.fill += (goal.fill-frame.fill)*easing
	if math.abs(goal.ny-frame.ny)<.0001 then frame.ny=goal.ny end
	if math.abs(goal.fill-frame.fill)<.0001 then frame.fill=goal.fill end
	local orthographic = self.camera.projection == engine.CameraProjectionMode.orthographic
	local orthoHeight = self.baseOrthoHeight/self.zoom
	if self.focusBlend>0 then
		local top = math.max(.5,avatarHeight or 1.8)
		local centre = target+vector.create(0,top*.5,0)
		local tanHalfFov = math.tan(math.rad(self.camera.fov)*.5)
		local focusDistance = top*1.12/(frame.fill*2*tanHalfFov)
		local direction = position-centre
		direction = vector.normalize(vector.create(direction.x,math.max(direction.y,.12*vector.magnitude(direction)),direction.z))
		local right = vector.normalize(vector.cross(vector.create(0,1,0),direction))
		local up = vector.normalize(vector.cross(direction,right))
		-- Tilt the wardrobe view up while retaining its framing above the drawer.
		direction=direction*math.cos(WARDROBE_TILT_UP)-up*math.sin(WARDROBE_TILT_UP)
		up=vector.normalize(vector.cross(direction,right))
		local focusedPosition = centre+direction*focusDistance
		local offset = up*(frame.ny*focusDistance*tanHalfFov)
		local focusedLook = centre-offset
		if orthographic then
			focusedPosition-=offset
			orthoHeight+=(top*1.12/frame.fill-orthoHeight)*self.focusBlend
		end
		position=vector.lerp(position,focusedPosition,self.focusBlend)
		focus=vector.lerp(focus,focusedLook,self.focusBlend)
	end
	if orthographic then self.camera.orthoHeight=orthoHeight end
	-- While the bottom is covered, tilt down so the player rises into the part
	-- of the view still showing. The camera stays put, so no new furniture
	-- comes between it and the player.
	local scale = if self.obscured > 0 or self.lift ~= 0 then worldPerPixel(self, focus) else nil
	if scale and scale > 0 then
		local wanted = self.obscured * LIFT_SHARE
		self.lift += (wanted - self.lift) * math.min(1, dt * LIFT_RESPONSE)
		if math.abs(wanted - self.lift) < .05 then self.lift = wanted end
		if self.lift ~= 0 then focus -= vector.create(0, self.lift * scale, 0) end
	end
	-- Avoid dirtying a settled scene every tick; keep the engine's idle pacing.
	local previousFocus = self.lastFocus
	if not previousFocus or vector.magnitude(position - self.camera.transform.worldPosition) > 0.00001 or vector.magnitude(focus - previousFocus) > 0.00001 then
		self.camera.transform.worldPosition = position
		self.camera.transform:lookAt({ target = focus })
		self.lastFocus = focus
	end
end

return Rig
