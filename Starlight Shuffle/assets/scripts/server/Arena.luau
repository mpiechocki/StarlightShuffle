--!strict
--@server
-- A place's world: one native scene at a time (the lobby, or the current
-- mini-game's) and one avatar per player in it, spawned on open floor around the
-- scene's `player-spawn`. Its owner moves it with movement reports from
-- @moonbase/prediction, which the server checks against the floor
-- (shared/Floor) and a speed budget before accepting them; a bad one earns a
-- correction back to the last good spot. @moonbase/replication sends the
-- avatars to everyone, each with two data parts: its packed motion, and its
-- identity (whose it is), each resent only when it changes.
--
-- `load` swaps the scene: everyone here is assigned the new one, and their
-- avatars land at its spawn. A cycle loads each mini-game's scene this way;
-- one replication stream for the whole instance keeps the clients' assignment
-- generations rising. Ported from Sky Lounge's server/World.
local scenes = require("@moonbase/scene")
local types = require("@moonbase/types")
local Replication = require("@moonbase/replication")
local Movement = require("@moonbase/movement")
local Net = require("../shared/Net")
local Floor = require("../shared/Floor")

local REPLICATE_EVERY = 0.1 -- seconds between replication steps
local REPLICATE_SLACK = 0.001 -- seconds of rounding a step may fall short by
local REPORT_HOLD = 0.5 -- seconds an avatar keeps moving after its owner's last report
local ARRIVAL = 2.5 -- metres from the spawn point that arrivals land within
local TRIES = 8 -- spots an arrival weighs before landing on the most open

export type Host = {
	send: (player: types.Player, channel: string, message: types.Value) -> (),
	clock: () -> number,
	tick: () -> number,
	identity: (session: number) -> Net.Identity?,
}
export type Arena = {
	-- Instantiates [scene] ("scene:<name>") and moves everyone here into it.
	load: (scene: string) -> (),
	join: (player: types.Player) -> (),
	leave: (player: types.Player) -> (),
	-- Handles replication and movement messages; false for any other.
	receive: (player: types.Player, kind: unknown, message: unknown) -> boolean,
	update: (dt: number) -> (),
	-- The native scene now loaded, for a mini-game's own entities and markers.
	world: () -> scenes.Scene,
	-- Where [session]'s avatar stands, as the server has it; nil for nobody.
	position: (session: number) -> vector?,
	-- Where the authored entity [name] stands; nil when the scene has none.
	marker: (name: string) -> vector?,
	-- Puts [session]'s avatar at [position] (snapped to the floor) and corrects its owner.
	teleport: (session: number, position: vector) -> (),
	dispose: () -> (),
}

type Actor = {
	entity: scenes.Entity,
	state: Movement.State, validator: Movement.Validator,
	-- The last report taken, the correction the owner must echo, when the last
	-- report came and how far the state is simulated.
	sequence: number, correction: number, reportAt: number?, simulated: number,
}

local function number(v: unknown, default: number): number
	return if type(v) == "number" and v == v and math.abs(v) < math.huge then v else default
end

local function finite(v: vector): boolean
	return v.x == v.x and v.y == v.y and v.z == v.z and math.abs(v.x) < math.huge
		and math.abs(v.y) < math.huge and math.abs(v.z) < math.huge
end

local Arena = {}

-- [avatar] is the prefab every player is spawned from.
function Arena.new(host: Host, avatar: scenes.Prefab): Arena
	local world: scenes.Scene? = nil
	local mesh: Floor.Floor? = nil
	local spawn = vector.zero
	local speed, stoppingDistance = 3, 0.05
	local players: {[number]: types.Player} = {} -- by session id: everyone here
	local actors: {[number]: Actor} = {} -- by session id
	local lastStep = -math.huge
	local replicas = Replication.server(function(peer: types.Player, channel: string, message: types.Value)
		if peer.isActive then host.send(peer, channel, message) end
	end, nil, host.clock)

	local function current(): scenes.Scene
		return assert(world, "The arena has no scene loaded")
	end

	-- Where an arrival lands: of a few spots on the floor within ARRIVAL of the
	-- spawn point, the one farthest from everyone already here.
	local function arrival(): vector
		local floor = mesh
		if not floor then return spawn end
		local best, widest = spawn, -1
		for _ = 1, TRIES do
			local point = floor:randomPoint({ center = spawn, radius = ARRIVAL })
			if point then
				local gap = math.huge
				for _, other in actors do
					local away = other.state.position - point
					gap = math.min(gap, away.x * away.x + away.z * away.z)
				end
				if gap > widest then best, widest = point, gap end
			end
		end
		return best
	end

	-- Advances the server's copy of an avatar to [now]: it keeps walking for a
	-- moment after the last report, then waits for the next one.
	local function simulate(actor: Actor, now: number): Movement.State
		local state = actor.state
		local untilTime = math.min(now, (actor.reportAt or now) + REPORT_HOLD)
		local remaining = math.max(0, untilTime - actor.simulated)
		while remaining > 0.000001 do
			local dt = math.min(remaining, 1 / 30)
			Movement.step(state, nil, dt, mesh)
			remaining -= dt
		end
		actor.simulated = math.max(actor.simulated, now)
		if untilTime < now then state.velocity = vector.zero end
		return state
	end

	local function stop(state: Movement.State)
		Movement.step(state, {sequence = state.lastProcessedInput + 1, stop = true}, 0, mesh)
	end

	local function motion(actor: Actor): buffer
		local now = host.clock()
		local state = simulate(actor, now)
		-- A report can land just before a replication step: sample the intent
		-- so observers do not see a false stop at every report.
		local sample = table.clone(state)
		sample.path = table.clone(state.path)
		Movement.step(sample, nil, 1 / 60, mesh)
		local v = if actor.reportAt and now - actor.reportAt >= REPORT_HOLD then vector.zero else sample.velocity
		local velocity = vector.create(math.round(v.x * 100) / 100, math.round(v.y * 100) / 100, math.round(v.z * 100) / 100)
		return Net.motion({ speed = state.speed, stoppingDistance = state.stoppingDistance, velocity = velocity,
			direction = state.direction, destination = state.destination, canMove = true, correction = actor.correction })
	end

	local function input(actor: Actor, report: Movement.Report)
		if report.sequence <= actor.sequence or report.correction ~= actor.correction then return end
		if not finite(report.position) then return end
		local direction, destination = report.direction, report.destination
		if direction and (not finite(direction) or math.abs(direction.y) > 0.001 or vector.magnitude(direction) > 1.001) then return end
		if destination and (not finite(destination) or vector.magnitude(destination - spawn) > 500) then return end
		local now = host.clock()
		local state = simulate(actor, now)
		actor.sequence = report.sequence
		local accepted = Movement.validate(actor.validator, report.position, now, mesh)
		if not accepted then
			-- One explicit correction; reports queued before the owner saw it
			-- carry the old correction and are dropped above.
			actor.correction += 1
			state.position = actor.validator.position
			stop(state)
		else
			state.position = accepted
			if not Movement.step(state, {sequence = state.lastProcessedInput + 1, stop = report.stop,
				direction = direction, destination = destination}, 0, mesh) then stop(state) end
		end
		actor.reportAt, actor.simulated = now, now
		actor.entity:setWorldPosition(state.position)
	end

	-- Spawns and replicates [player]'s avatar in the loaded scene.
	local function arrive(player: types.Player)
		local scene = world
		if not scene then return end
		local session = player.session_id
		local position = arrival()
		local entity = scene:spawn(avatar)
		entity:setWorldPosition(position)
		local now = host.clock()
		local actor: Actor = {
			entity = entity,
			state = Movement.create(position, speed, stoppingDistance), validator = Movement.validator(position, speed, now),
			sequence = 0, correction = 0, reportAt = nil, simulated = now,
		}
		actors[session] = actor
		replicas:track(entity, avatar, {
			motion = function(): types.Value return motion(actor) end,
			identity = function(): types.Value?
				local who = host.identity(session)
				return if who then Net.identity(who) else nil
			end,
		})
	end

	local function depart(session: number)
		local actor = actors[session]
		if not actor then return end
		actors[session] = nil
		replicas:untrack(actor.entity)
		if actor.entity.isValid then actor.entity:destroy() end
	end

	return {
		load = function(scene: string)
			for session in table.clone(actors) do depart(session) end
			if world then world:destroy() end
			local loaded = scenes.instantiate(scene)
			world = loaded
			mesh = Floor.of(loaded)
			if not mesh then print(scene .. " has neither a baked navmesh nor a walk-area: avatars walk anywhere") end
			local marker = loaded:getAuthored("player-spawn")
			local at = if marker then marker:worldPosition() else vector.zero
			spawn = if mesh then mesh:nearestPoint(at) or at else at
			-- Movement tuning lives on the avatar prefab.
			local probe = loaded:spawn(avatar)
			local settings = probe:component("movement")
			local properties: {read [string]: unknown} = if settings then settings.properties else {}
			speed, stoppingDistance = number(properties.speed, 3), number(properties.stoppingDistance, 0.05)
			probe:destroy()
			-- Everyone here is assigned the new scene (a fresh generation each).
			replicas:setWorld(loaded, scene)
			for _, player in players do arrive(player) end
			lastStep = -math.huge
		end,
		join = function(player: types.Player)
			local session = player.session_id
			if players[session] then return end
			players[session] = player
			arrive(player)
			replicas:assign(player)
		end,
		leave = function(player: types.Player)
			players[player.session_id] = nil
			replicas:forget(player)
			depart(player.session_id)
		end,
		receive = function(player: types.Player, kind: unknown, message: unknown): boolean
			if replicas:receive(player, kind, message) then return true end
			if kind ~= Net.MOVE then return false end
			local actor, assigned = actors[player.session_id], replicas.peers[player]
			local report, generation = Net.readReport(message)
			-- Reports made for an earlier assignment are stale.
			if actor and assigned and report and generation == assigned.generation then input(actor, report) end
			return true
		end,
		update = function(dt: number)
			local scene = world
			if not scene then return end
			local now = host.clock()
			for _, actor in actors do
				actor.entity:setWorldPosition(simulate(actor, now).position)
			end
			scene:step(dt)
			-- The clock adds up tick lengths, so a step's worth can come out a
			-- hair short of REPLICATE_EVERY.
			if now - lastStep >= REPLICATE_EVERY - REPLICATE_SLACK then
				lastStep = now
				replicas:step(host.tick())
			end
		end,
		world = current,
		position = function(session: number): vector?
			local actor = actors[session]
			return if actor then actor.state.position else nil
		end,
		marker = function(name: string): vector?
			local entity = if world then world:getAuthored(name) else nil
			return if entity then entity:worldPosition() else nil
		end,
		teleport = function(session: number, position: vector)
			local actor = actors[session]
			if not actor or not finite(position) then return end
			local target = if mesh then mesh:nearestPoint(position) or position else position
			local now = host.clock()
			actor.correction += 1
			actor.state.position = target
			stop(actor.state)
			actor.validator = Movement.validator(target, speed, now)
			actor.reportAt, actor.simulated = now, now
			actor.entity:setWorldPosition(target)
		end,
		dispose = function()
			for session in table.clone(actors) do depart(session) end
			if world then world:destroy(); world = nil end
		end,
	}
end

return table.freeze(Arena)
