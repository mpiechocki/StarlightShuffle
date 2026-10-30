--!strict
--@client
-- The place's world as the server replicates it (@moonbase/replication and
-- its presentation adapter): the scene the server assigns (the lobby, or the
-- cycle's current mini-game) and every avatar in it. Our own avatar walks
-- under @moonbase/prediction and reports its movement; everyone else's follows
-- the server's poses. Each avatar's data parts are its motion and its
-- identity: whose it is, with their name, outfit and thumbnail. HELLO says who
-- we are and which place this is (`onHello` hears it, in each place). `roster`
-- lists everyone whose avatar we see. `onReady` hears once that there is a
-- world to show: our own avatar stands in it dressed, or it failed to load.
-- Ported from Sky Lounge's client/Multiplayer.
--
-- Arrivals drop in (PlayerController.arrive) once dressed: our own avatar in
-- each place we come to, and anyone who comes after us. Whoever was already
-- there when we came simply stands there. `onArrive` hears an arrival start
-- and `onLanded` its avatar touch down.
local client = require("@moonbase/client")
local game = require("@moonbase/game")
local engine = require("@moonbase/engine")
local Replication = require("@moonbase/replication")
local Prediction = require("@moonbase/prediction")
local Movement = require("@moonbase/movement")
local Presentation = require("@moonbase/presentation")
local Net = require("../shared/Net")
local Appearance = require("./Appearance")
local Roster = require("./Roster")
local Avatars = require("../gameplay/Avatars")
local Controls = require("../gameplay/Controls")
local Player = require("../gameplay/PlayerController")

-- Our session id, shown name and the kind of place we are in.
export type Me = { id: number, name: string, place: Net.Place }
-- A visible player's avatar and who they are. `replica` is the record last
-- reconciled and `dressed` the outfit last shown; `layered` once that outfit's
-- animated layers are shown or known not to be needed.
-- `arriving` while it waits for its outfit to drop in.
export type Avatar = {
	parts: Avatars.Avatar, session: number, player: number, record: number, mine: boolean,
	identity: Net.Identity, controller: Player.Controller, replica: any, dressed: {number}?, layered: boolean,
	arriving: boolean,
}
type Fields = {
	controls: Controls.Controller, outfit: {number}, avatar: string?,
	me: Me?, roster: Roster.Roster, rostered: boolean, scene: engine.Scene?, sceneName: string?,
	replication: any, adapter: any,
	avatars: {[number]: Avatar}, -- by session
	controlled: {[number]: Player.Controller}, -- by replicated root id
	looked: boolean, sequence: number, failedAt: number?,
	-- game.clock() as of this tick (see tick): every avatar's prediction
	-- reads the clock each update, and it only moves between ticks.
	now: number,
	onScene: ((engine.Scene?) -> ())?, onMine: ((Avatar) -> ())?, onLeft: ((number) -> ())?,
	onReady: (() -> ())?, onArrive: ((Avatar) -> ())?, onLanded: ((Avatar) -> ())?, onHello: ((Me) -> ())?,
	-- Whether our own avatar is here (anyone new from now on arrives), and
	-- whether it has arrived in this place.
	settled: boolean, arrived: boolean,
	unsubscribe: (() -> ())?,
}
local Multiplayer = {}
Multiplayer.__index = Multiplayer
export type Controller = typeof(setmetatable({} :: Fields, Multiplayer))

-- A part keeps its value until that part changes, so each is decoded once.
-- (false marks a value that is not one.)
local motions: {[any]: any} = setmetatable({}, {__mode = "k"})
local identities: {[any]: any} = setmetatable({}, {__mode = "k"})

local function motionOf(record: any): Movement.Motion?
	local value = if record.parts then record.parts.motion else nil
	if value == nil then return nil end
	if motions[value] == nil then motions[value] = Net.readMotion(value) or false end
	return motions[value] or nil
end

local function identityOf(record: any): Net.Identity?
	local value = if record.parts then record.parts.identity else nil
	if value == nil then return nil end
	if identities[value] == nil then identities[value] = Net.readIdentity(value) or false end
	return identities[value] or nil
end

local function forget(self: Controller)
	for session in self.avatars do
		if self.onLeft then self.onLeft(session) end
	end
	table.clear(self.avatars)
	table.clear(self.controlled)
	self.rostered, self.settled, self.arrived = false, false, false
end

-- [outfit] is what the local player wears unless their identity says
-- otherwise, and [avatar] their own thumbnail's media id unless it gives one.
function Multiplayer.new(controls: Controls.Controller, outfit: {number}, avatar: string?): Controller
	local self = setmetatable({
		controls = controls, outfit = outfit, avatar = avatar, me = nil, roster = Roster.new(), rostered = false,
		scene = nil, sceneName = nil,
		replication = nil, adapter = nil, avatars = {}, controlled = {},
		looked = false, sequence = 0, failedAt = nil, now = game.clock(), onScene = nil, onMine = nil, onLeft = nil,
		onReady = nil, onArrive = nil, onLanded = nil, onHello = nil, settled = false, arrived = false, unsubscribe = nil,
	} :: Fields, Multiplayer)
	-- Loading the scene we already show just hands it back.
	local stage = setmetatable({
		loadScene = function(name: string): any
			local scene = self.scene
			if scene and scene.isValid and self.sceneName == name then
				return { andThen = function(_: any, done: (engine.Scene) -> ()) done(scene) end }
			end
			local loading = game.loadScene(name)
			loading:andThen(function(_: engine.Scene) self.sceneName = name end)
			return loading
		end,
	}, {__index = game})
	self.adapter = Presentation.new(stage, function(scene: engine.Scene?)
		-- The adapter took the previous avatars with it.
		self.scene = scene
		forget(self)
		if self.onScene then self.onScene(scene) end
	end, {ownsTransform = function(record: any): boolean
		-- A controller owns its avatar's root once placed, and the cosmetic visual always.
		local controller = self.controlled[record.root]
		return controller ~= nil and (record.id ~= record.root or (controller.prediction ~= nil and controller.prediction.ready))
	end})
	self.replication = Replication.client(client.notifyServer, self.adapter)
	self.unsubscribe = client.onMessage(function(kind: unknown, a: unknown, b: unknown, c: unknown)
		if kind == Net.HELLO then
			local id, place = Net.id(a), Net.place(c)
			if id and type(b) == "string" and place then
				local me: Me = { id = id, name = b, place = place }
				self.me = me
				if self.onHello then self.onHello(me) end
			end
		else
			self.replication:receive(kind, a)
		end
	end)
	return self
end

-- Puts [identity]'s player in charge of the avatar replicated as root [id].
local function adopt(self: Controller, identity: Net.Identity, id: number, root: any, mine: boolean)
	local parts = Avatars.from(root.visual, root.native, root.visuals)
	local controller = Player.new(parts.entity, parts.native, parts.visual, parts.renderer)
	if not controller then return end
	local previous = self.avatars[identity.session]
	if previous then self.controlled[previous.record] = nil end
	-- Named after its session, so hierarchies and tests can find it.
	parts.entity.name = "player:" .. identity.session
	-- We arrive once in each place; anyone else only when they came after us.
	local arriving = if mine then not self.arrived else self.settled and previous == nil
	if arriving then controller:hide() end
	local avatar: Avatar = { parts = parts, session = identity.session, player = identity.player, record = id, mine = mine,
		identity = identity, controller = controller, replica = nil, dressed = nil, layered = false, arriving = arriving }
	self.avatars[identity.session], self.controlled[id] = avatar, controller
	self.rostered = false
	-- Reports name the assignment they were made in, so stale ones are dropped.
	controller.prediction = Prediction.new(controller.state, controller.mesh, { clock = function(): number return self.now end,
		send = if mine then function(report: buffer) client.notifyServer(Net.MOVE, report) end else nil,
		scope = function(): {number} return {math.max(0, self.replication.generation)} end,
		nextSequence = if mine then function(): number self.sequence += 1; return self.sequence end else nil })
	controller.command = if mine then function(input: any): boolean return controller.prediction:input(input) end else nil
	if mine then
		self.controls:setPlayer(parts.entity, controller)
		if self.onMine then self.onMine(avatar) end
	end
end

-- Adopts avatars the adapter has spawned and drops those it removed.
local function sync(self: Controller)
	local roots = self.adapter.state.roots
	local seen: {[number]: boolean} = {}
	for id, record in self.replication.records do
		if record.id ~= record.root then continue end
		local identity, root = identityOf(record), roots[id]
		if identity and root then
			seen[identity.session] = true
			local mine = self.me ~= nil and (self.me :: Me).id == identity.session
			local avatar = self.avatars[identity.session]
			if not avatar or avatar.record ~= id or avatar.mine ~= mine then adopt(self, identity, id, root, mine)
			elseif avatar.identity ~= identity then avatar.identity, self.rostered = identity, false end
		end
	end
	for session, avatar in self.avatars do
		if not seen[session] then
			self.controlled[avatar.record], self.avatars[session] = nil, nil
			self.rostered = false
			if self.onLeft then self.onLeft(session) end
		end
	end
	-- Whoever came with us was already here; anyone from now on arrives.
	local me = self.me
	if me and self.avatars[me.id] then self.settled = true end
end

-- Everyone we see, once something about them changed.
local function list(self: Controller)
	if self.rostered then return end
	self.rostered = true
	local members: {Roster.Member} = {}
	for session, avatar in self.avatars do
		local identity = avatar.identity
		table.insert(members, { session = session, player = identity.player, name = identity.name, mine = avatar.mine,
			avatar = identity.avatar or (if avatar.mine then self.avatar else nil) })
	end
	self.roster:set(members)
end

-- Hands each changed server pose to its avatar's movement driver.
local function reconcile(self: Controller)
	local records = self.replication.records
	for _, avatar in self.avatars do
		local record = records[avatar.record]
		if record and avatar.replica ~= record then
			local motion = motionOf(record)
			if motion then
				local first = avatar.replica == nil
				avatar.controller.prediction:checkpoint(record.position, motion, record.time or self.now, first)
				if first or motion.canMove == false then
					avatar.controller.input, avatar.controller.destination = vector.zero, nil
				end
			end
			avatar.replica = record
		end
	end
end

local RETRY = 2 -- seconds before a failed scene load or stream starts over

-- Tells onReady, once.
local function ready(self: Controller)
	local callback = self.onReady
	self.onReady = nil
	if callback then callback() end
end

-- Reads the clock for this tick; call before anything moves an avatar.
function Multiplayer.tick(self: Controller)
	self.now = game.clock()
end

function Multiplayer.update(self: Controller, dt: number)
	local failure = self.replication.error
	if failure then
		local now = game.clock()
		if not self.failedAt then
			self.failedAt = now
			print("World replication failed: " .. tostring(failure))
			ready(self)
		elseif now - (self.failedAt :: number) >= RETRY then
			self.failedAt = nil
			self.replication:retry()
		end
	end
	-- The look goes out once per place; players with an outfit in their
	-- metadata are shown in that one instead.
	if not self.looked and self.me then
		client.notifyServer(Net.LOOK, Net.list(self.outfit))
		self.looked = true
	end
	sync(self)
	list(self)
	reconcile(self)
	local rig = self.controls.rig
	local yaw = if rig then rig.yaw else 0
	local camera = if rig and rig.camera.isValid then rig.camera.transform.worldPosition else nil
	for session, avatar in self.avatars do
		local renderer = avatar.parts.renderer
		if renderer.isValid then
			local outfit = avatar.identity.outfit or (if avatar.mine then self.outfit else nil) or Appearance.STARTER
			if avatar.dressed ~= outfit then
				avatar.dressed, avatar.layered = outfit, false
				renderer.appearance = Appearance.render(outfit)
			end
			-- The still composite shows at once; animated pieces swap in once loaded.
			if not avatar.layered then
				local layered = Appearance.layered(outfit)
				if layered ~= nil then
					avatar.layered = true
					if layered then renderer.appearance = layered end
				end
			end
			-- Our own outfit has loaded (or failed to).
			if avatar.mine and not renderer.loading then ready(self) end
			-- Dressed: an arrival drops in.
			if avatar.arriving and not renderer.loading then
				avatar.arriving = false
				if avatar.mine then self.arrived = true end
				avatar.controller:arrive(function() if self.onLanded then self.onLanded(avatar) end end)
				if self.onArrive then self.onArrive(avatar) end
			end
		end
		-- Controls update our own avatar.
		if not avatar.mine and avatar.controller.transform.isValid then avatar.controller:update(dt, yaw, camera) end
	end
end

-- The shown name of a session's player, from its avatar's identity.
function Multiplayer.name(self: Controller, session: number): string?
	local avatar = self.avatars[session]
	return if avatar then avatar.identity.name else nil
end

-- Another server instance: a new assignment, its own avatars, and
-- we are told who we are again.
function Multiplayer.transferred(self: Controller)
	self.replication:dispose()
	self.replication = Replication.client(client.notifyServer, self.adapter)
	forget(self)
	self.roster:set({})
	self.me, self.looked, self.sequence, self.failedAt = nil, false, 0, nil
end

function Multiplayer.dispose(self: Controller)
	if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
	self.replication:dispose()
	forget(self)
	self.roster:set({})
	table.clear(self.roster.listeners)
	self.onScene, self.onMine, self.onLeft, self.onReady, self.onArrive, self.onLanded = nil, nil, nil, nil, nil, nil
	self.onHello = nil
end

return Multiplayer
