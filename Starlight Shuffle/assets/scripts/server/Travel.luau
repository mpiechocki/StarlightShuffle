--!strict
--@server
-- Moving players between places (server instances). A place of a profile
-- ("lobby" or "cycle") with room is found among the running instances, the
-- fullest first so players end up together; when none has room, a new one is
-- started. A place that fills before the transfer lands is passed over for the
-- next. These helpers yield: call them inside Task.run.
local server = require("@moonbase/server")
local hosting = require("@moonbase/hosting")
local Task = require("@moonbase/task")

local TRIES = 3 -- places tried before a move gives up as full

export type Data = hosting.TransferData
local Travel = {}

local function list(): {server.InstanceInfo}
	return Task.value(function(done: (server.HostResult<{server.InstanceInfo}>) -> ())
		server.instances.list({}, done)
	end)
end

-- Whether [info] is a running place of [profile] with [seats] free.
local function open(info: server.InstanceInfo, profile: string, seats: number): boolean
	return info.profile_id == profile and info.state == "ready"
		and info.instance_id ~= server.context.instance_id
		and info.connections + seats <= info.max_connections
end

-- The id of a place of [profile] with room for [seats] players, skipping
-- [tried]; [prefer] wins when it has room. Starts one when none has.
function Travel.place(profile: string, seats: number, tried: {string}, prefer: string?): string
	local best: server.InstanceInfo? = nil
	for _, info in list() do
		if open(info, profile, seats) and not table.find(tried, info.instance_id) then
			if info.instance_id == prefer then return info.instance_id end
			if not best or info.connections > best.connections then best = info end
		end
	end
	if best then return best.instance_id end
	return hosting.startReady(profile, hosting.operationId()).instance_id
end

-- Transfers [players] together to a place of [profile] (to [prefer] when it
-- has room), carrying [data]. Returns true once they are on their way; false
-- and the error code when every try failed.
function Travel.send(players: {server.Player}, profile: string, data: Data?, prefer: string?): (boolean, string?)
	local tried: {string} = {}
	local code: string? = nil
	for _ = 1, TRIES do
		local active: {server.Player} = {}
		for _, player in players do
			if player.isActive then table.insert(active, player) end
		end
		if #active == 0 then return true, nil end
		local destination = Travel.place(profile, #active, tried, prefer)
		local ok, err = pcall(function() hosting.transferAndWait(active, destination, hosting.operationId(), data) end)
		if ok then return true, nil end
		code = Task.failure(err).code
		if code ~= "capacity_unavailable" then return false, code end
		table.insert(tried, destination)
	end
	return false, code
end

-- A running cycle as its metadata describes it (Travel.publish): its phase, the
-- mini-game on or coming, how many are in it, and when its phase ends
-- (seconds since 1970: os.time, which every instance shares).
export type Cycle = { id: string, phase: string, game: string?, players: number, ends: number, room: number }

-- The cycles running now (yields).
function Travel.cycles(): {Cycle}
	local out: {Cycle} = {}
	for _, info in list() do
		local m: {[string]: string} = info.metadata or {}
		local players, ends, phase, game = tonumber(m.players), tonumber(m.ends), m.phase, m.game
		if info.profile_id == "cycle" and info.state == "ready" and type(phase) == "string" and players and ends then
			table.insert(out, { id = info.instance_id, phase = phase, game = if type(game) == "string" and game ~= "" then game else nil,
				players = players, ends = ends, room = info.max_connections - info.connections })
		end
	end
	return out
end

-- Tells other places what this one is doing ([metadata], strings), for
-- Travel.cycles; a newer call wins over one still on its way.
local published = 0
function Travel.publish(metadata: {[string]: string})
	published += 1
	local mine = published
	local id = server.context.instance_id
	local function try(attempt: number)
		server.instances.get({instance_id = id}, function(result: server.HostResult<server.InstanceInfo>)
			if mine ~= published then return end
			if not result.ok then print("Publishing place state failed: " .. result.error.message); return end
			server.instances.setMetadata({instance_id = id, revision = result.value.revision, metadata = metadata},
				function(set: server.HostResult<boolean>)
					-- Someone else changed it meanwhile (a revision conflict): read it again.
					if not set.ok and attempt < 3 and mine == published then try(attempt + 1) end
				end)
		end)
	end
	try(1)
end

-- Transfers [players] to the place [destination] exactly, carrying [data]
-- (yields). Returns whether they are on their way, and the error code if not.
function Travel.sendTo(players: {server.Player}, destination: string, data: Data?): (boolean, string?)
	local active: {server.Player} = {}
	for _, player in players do
		if player.isActive then table.insert(active, player) end
	end
	if #active == 0 then return true, nil end
	local ok, err = pcall(function() hosting.transferAndWait(active, destination, hosting.operationId(), data) end)
	if ok then return true, nil end
	return false, Task.failure(err).code
end

-- Stops this place once [empty]() has held for [grace] seconds; call [check]
-- whenever someone joins or leaves. The host never stops idle instances.
function Travel.idleStop(grace: number, empty: () -> boolean): () -> ()
	local cancel: (() -> ())? = nil
	return function()
		if not empty() then
			if cancel then cancel(); cancel = nil end
			return
		end
		if cancel then return end
		cancel = server.after(grace, function()
			cancel = nil
			if not empty() then return end
			print("Stopping idle place " .. server.context.instance_id)
			server.instances.stop({instance_id = server.context.instance_id}, function(result)
				if not result.ok then print("Idle stop failed: " .. result.error.message) end
			end)
		end)
	end
end

return table.freeze(Travel)
