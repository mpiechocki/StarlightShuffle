--!strict
--@client
local engine = require("@moonbase/engine")
local scenes = require("@moonbase/scene")
local movement = require("@moonbase/movement")
local Appearance = require("../client/Appearance")
local Floor = require("../shared/Floor")
local Player = {}
Player.__index = Player

-- Movement state belongs to this controller and advances exactly once per update.
-- The native entity owns its position; the rendering transform displays it.
-- Cosmetic bob/lean/hop offsets remain on the optional visual child.
local HOP_SECONDS = 0.26
local HOP_HEIGHT = 0.06
local LEAN_DEGREES = 2.5
local BOB_HZ = 17
local LIFT_RESPONSE = 12 -- 1/s; how quickly the doll follows its lift
local FLOAT_SWAY_DEGREES = 3 -- roll while floating, at a 0.2 m lift
local FLOAT_SWAY_HZ = 1.4
local REGROUND = 2 -- seconds between reads of a loaded outfit's box
-- An arrival (see arrive): the doll drops ARRIVAL_DROP metres in ARRIVAL_FALL
-- seconds, then squashes and wobbles still over ARRIVAL_SETTLE.
local ARRIVAL_DROP = 0.6
local ARRIVAL_FALL = 0.42
local ARRIVAL_SETTLE = 0.55
local HIDDEN = 0.001 -- the scale of a doll waiting to arrive: unseen, but never singular

type Fields = {
	transform: engine.Transform,
	native: scenes.Entity,
	state: movement.State, sequence: number,
	mesh: movement.NavMesh?,
	visual: engine.Transform?,
	renderer: engine.AvatarRendererComponent?,
	grounding: number,
	-- When the outfit's box was last read for [grounding] (nil: read it
	-- once the outfit has loaded).
	groundedAt: number?,
	-- The scale last written to the doll (its facing, and any arrival), and the
	-- positions last written to the presentation and native entities: every
	-- one costs a host call, and a crowd mostly stands still.
	shownScale: vector?,
	shownPosition: vector?, nativePosition: vector?,
	baseScale: vector,
	input: vector,
	destination: vector?,
	speed: number,
	-- Motion state read by the follow camera: whether the player moved this
	-- frame and its velocity eased the way the R&D doll's was, so the camera
	-- lead ramps in and drifts out over about a second instead of snapping.
	walking: boolean,
    gaitTime: number, locomotionWeight: number,
	leadVelocity: vector,
	facing: number,
	shownFacing: number,
	lean: number,
	hop: number,
	-- Metres the doll floats above its pose (someone is holding it, client/Holds),
	-- and the height it shows while easing there.
	lift: number,
	lifted: number,
	-- Waiting to arrive (unseen), or seconds into an arrival; [onLand] hears it
	-- touch down.
	hidden: boolean, arrival: number?, onLand: (() -> ())?,
	time: number,
	lastPose: vector?,
	-- The port supplies a locally simulated movement/reporting driver. Standalone
	-- controls step the same Luau movement library when this is absent.
	command: ((any) -> boolean)?,
    prediction: any,
	externalVelocity: vector?,
}
export type Controller = typeof(setmetatable({} :: Fields, Player))

-- An actor is its presentation entity plus its native counterpart, which
-- carries the "movement" MovementSettings component (see prefabs/Avatar).
function Player.new(entity: engine.Entity, native: scenes.Entity, visual: engine.Entity?, renderer: engine.AvatarRendererComponent?): Controller?
    local settings = native:component("movement")
    if not settings then return nil end
    -- The baked navmesh, or the walk area of a scene without one (shared/Floor).
    local mesh: movement.NavMesh? = Floor.of(native.scene)
    local position = native:worldPosition()
    local snapped = if mesh then mesh:nearestPoint(position) else nil
    if snapped then position = snapped; native:setWorldPosition(position) end
    local state = movement.create(position, settings.properties.speed :: number, settings.properties.stoppingDistance :: number)
	local visualTransform = if visual and visual.isValid then visual.transform else nil
	return setmetatable({
		transform = entity.transform, native = native, state = state, sequence = 0, mesh = mesh,
		visual = visualTransform, baseScale = if visualTransform then visualTransform.scale else vector.one,
		renderer = renderer, grounding = 0, groundedAt = nil,
		shownScale = nil, shownPosition = nil, nativePosition = nil,
		input = vector.zero, destination = nil, speed = state.speed,
		walking = false, gaitTime = 0, locomotionWeight = 0, leadVelocity = vector.zero, facing = 1, shownFacing = 1,
		lean = 0, hop = 0, lift = 0, lifted = 0, hidden = false, arrival = nil, onLand = nil, time = 0, lastPose = nil,
		command = nil, prediction = nil, externalVelocity = nil,
	} :: Fields, Player)
end

function Player.joystick(self: Controller, dx: number, dy: number)
	self.sequence += 1
    if not self.prediction then movement.step(self.state, {sequence=self.sequence, stop=true}, 0, self.mesh) end
	self.destination = nil
	local magnitude = math.sqrt(dx * dx + dy * dy)
	self.input = if magnitude <= 14 then vector.zero else vector.create(dx, 0, dy) / magnitude * math.clamp((magnitude - 14) / 42, 0.2, 1)
	if self.command and magnitude <= 14 then self.command({stop=true}) end
end

function Player.stop(self: Controller)
	self.input = vector.zero
	self.destination = nil
	self.sequence += 1
    if not self.prediction then movement.step(self.state, {sequence=self.sequence, stop=true}, 0, self.mesh) end
	if self.command then self.command({stop=true}) end
end

-- Returns false when the point is off the navmesh and no path was planned.
function Player.walkTo(self: Controller, point: vector): boolean
	self.input = vector.zero
	if self.command then
        local target=if self.mesh then self.mesh:nearestPoint(point) else point
        return if target then self.command({destination=target}) else false
    end
	local mesh = self.mesh
	local target = if mesh then mesh:nearestPoint(point) else vector.create(point.x, self.transform.worldPosition.y, point.z)
	if not target then return false end
    self.sequence += 1
    self.state.position = self.native:worldPosition()
    if not movement.step(self.state, {sequence=self.sequence, destination=target}, 0, mesh) then return false end
    self.destination = self.state.destination
	return true
end

-- Keeps the doll unseen until it arrives.
function Player.hide(self: Controller)
	self.hidden = true
end

-- Drops the doll in from above, landing with a squash; [onLand] hears it
-- touch down.
function Player.arrive(self: Controller, onLand: (() -> ())?)
	self.hidden, self.arrival, self.onLand = false, 0, onLand
end

-- Whether the doll has yet to arrive or is still arriving.
function Player.arriving(self: Controller): boolean
	return self.hidden or self.arrival ~= nil
end

-- Where the arrival has got to, advanced [dt]: metres above the doll's pose,
-- and how much it stretches across and up. It falls faster and faster, drawn
-- out as it goes, then lands squashed and wobbles still.
function Player.arrivalPose(self: Controller, dt: number): (number, number, number)
	if self.hidden then return ARRIVAL_DROP, HIDDEN, HIDDEN end
	local t = self.arrival
	if not t then return 0, 1, 1 end
	t += dt
	self.arrival = t
	if t < ARRIVAL_FALL then
		local f = t / ARRIVAL_FALL
		return ARRIVAL_DROP * (1 - f * f), 1 - 0.06 * f, 1 + 0.1 * f
	end
	local onLand = self.onLand
	if onLand then self.onLand = nil; onLand() end
	local s = t - ARRIVAL_FALL
	if s >= ARRIVAL_SETTLE then self.arrival = nil; return 0, 1, 1 end
	local wobble = math.exp(-s * 8) * math.cos(s * 24)
	return 0, 1 + 0.12 * wobble, 1 - 0.16 * wobble
end

function Player.velocity(self: Controller): vector
	return self.externalVelocity or self.state.velocity
end

-- `yaw` is the camera's orbit so stick input stays screen-relative;
-- `cameraPosition` turns the visual toward the camera like the R&D billboards.
function Player.update(self: Controller, dt: number, yaw: number, cameraPosition: vector?)
	local direction: vector? = nil
	if vector.magnitude(self.input) > 0 then
		local c, s = math.cos(yaw), math.sin(yaw)
		-- The R&D controller used 50 floor units/metre and a 0.75 depth factor.
		local velocity = vector.create(self.input.x * c + self.input.z * s, 0, (-self.input.x * s + self.input.z * c) * 0.75) * self.speed
		if self.command then
			self.command({direction=velocity/self.speed})
		else direction = velocity / self.speed end
	end
    if self.prediction then
        local position=self.prediction:update(dt)
        local simulated=self.prediction.state.position
        -- Until the first server pose places it, replication moves the root.
        if not self.prediction.ready then self.shownPosition, self.nativePosition = nil, nil end
        if simulated ~= self.nativePosition then
            self.native:setWorldPosition(simulated)
            self.nativePosition = if self.prediction.ready then simulated else nil
        end
        self.externalVelocity=self.prediction.state.velocity
        if position ~= self.shownPosition then
            self.transform.worldPosition=position
            self.shownPosition = if self.prediction.ready then position else nil
        end
        self.destination=self.prediction.state.destination
    elseif not self.command then
        self.state.position = self.native:worldPosition()
        self.state.speed = self.speed
        local input: movement.Input? = nil
        if direction then
            self.sequence += 1
            local command: movement.Input = {sequence=self.sequence, direction=direction}
            input = command
        end
        movement.step(self.state, input, dt, self.mesh)
        self.native:setWorldPosition(self.state.position)
        self.transform.worldPosition = self.state.position
        self.shownPosition = self.state.position
        self.destination = self.state.destination
    end
    self:animate(dt, yaw, cameraPosition)
end

function Player.animate(self: Controller, dt: number, yaw: number, cameraPosition: vector?)
	local velocity = self:velocity()
	local speed=vector.magnitude(velocity)
	local walking = speed > (if self.walking then 0.025 else 0.05)
	self.walking = walking
	self.leadVelocity += (velocity - self.leadVelocity) * math.min(1, dt * 6)
	if not walking and vector.magnitude(self.leadVelocity) < 0.01 then self.leadVelocity = vector.zero end
	self.time += dt
    if walking then self.gaitTime+=dt*math.min(1,speed/self.speed) end
    self.locomotionWeight+=((if walking then 1 else 0)-self.locomotionWeight)*(1-math.exp(-dt/(if walking then 0.06 else 0.12)))
    if not walking and self.locomotionWeight<0.001 then self.locomotionWeight=0 end
	-- Facing follows the screen-relative direction of travel; walking straight
	-- toward or away from the camera keeps the last facing rather than jittering.
	local side = vector.dot(velocity, vector.create(math.cos(yaw), 0, -math.sin(yaw)))
	if walking then
		if math.abs(side) > self.speed * 0.1 then self.facing = math.sign(side) end
	end
	if self.facing ~= self.shownFacing then
		self.shownFacing = self.facing
		self.hop = HOP_SECONDS
	end
	-- Only sideways travel adds a lean. Forward/backward steps keep the same
	-- roll amplitude, centred on upright instead of the last facing direction.
	local lean = if walking then math.clamp(side / speed, -1, 1) * LEAN_DEGREES else 0
	self.lean += (lean - self.lean) * math.min(1, dt * 9)
	local hop = 0
	if self.hop > 0 then
		self.hop -= dt
		hop = HOP_HEIGHT * math.sin(math.pi * (1 - math.max(0, self.hop) / HOP_SECONDS))
	end
	local visual = self.visual
	if not visual or not visual.isValid then return end
	-- The outfit's box once it has loaded, and now and then after.
	local renderer = self.renderer
	if renderer and renderer.isValid then
		local read = self.groundedAt
		if renderer.loading then
			self.groundedAt = nil
		elseif not read or self.time - read > REGROUND then
			self.grounding = Appearance.groundOffset(renderer.contentBounds) * self.baseScale.y
			self.groundedAt = self.time
		end
	end
	self.lifted += (self.lift - self.lifted) * math.min(1, dt * LIFT_RESPONSE)
	if math.abs(self.lift - self.lifted) < 0.0005 then self.lifted = self.lift end
	local sway = math.sin(self.time * FLOAT_SWAY_HZ * 2 * math.pi) * FLOAT_SWAY_DEGREES * self.lifted / 0.2
	local bob = math.sin(self.gaitTime * BOB_HZ)*self.locomotionWeight
	local drop, wide, tall = self:arrivalPose(dt)
	local y = self.grounding + 0.02*self.locomotionWeight + bob*0.02 + hop + self.lifted + drop
	local roll = -(bob * 1.2 + self.lean + sway) * math.pi / 180
	local facingYaw = 0
	if cameraPosition then
		local here = self.shownPosition or self.transform.worldPosition
		facingYaw = math.atan2(cameraPosition.x - here.x, cameraPosition.z - here.z)
	end
	-- Leave a settled doll alone so an idle scene keeps the engine's idle pacing.
	local pose = vector.create(y, facingYaw, roll)
	local scale = vector.create(self.baseScale.x * self.facing * wide, self.baseScale.y * tall, self.baseScale.z)
	local last = self.lastPose
	local scaled = scale ~= self.shownScale
	if last and not scaled and vector.magnitude(pose - last) < 0.00001 then return end
	self.lastPose = pose
	visual.position = vector.create(0, y, 0)
	visual.rotation = vector.create(0, facingYaw, roll)
	if scaled then
		visual.scale = scale
		self.shownScale = scale
	end
end

return Player
