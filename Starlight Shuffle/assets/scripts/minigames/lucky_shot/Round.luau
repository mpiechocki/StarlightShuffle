--!strict
--@server
-- Lucky Shot's authoritative round on the cycle's server (see Rules for the
-- tuning, the cloud field and the wire format; Server hands it the cycle's
-- context).
--
-- When the cycle announces the mini-game (`new`), everyone here competes; the
-- roster is frozen then and each player takes a seat, numbered by player id,
-- that never changes. Anyone who arrives later watches. Play starts when the
-- shared 10-second announcement ends; the cloud field's size and pace come
-- once from the roster's size. The server draws each cloud as it appears and
-- announces it (SPAWN) only a moment before it shows; nothing further ahead
-- is known to clients.
--
-- Clients send shot intents for a cloud, never scores. A shot counts once per
-- sequence; a shot at a cloud never announced, before the start, at or after
-- the end, or inside the 850 ms reload is refused to its sender (REJECT) and
-- costs nothing. Any other shot takes the reload, then claims its cloud if
-- the cloud is still there at the shot's time: the first such claim the
-- server orders wins, and later ones are answered with no score ("claimed").
-- A shot at a cloud already gone at that time scores nothing either
-- ("expired"). Everyone hears every accepted shot (SHOT); clouds left alone
-- simply expire. Storms take a point, and scores may go below zero.
--
-- A player who disconnects keeps their seat, score and reload; a reconnection
-- gets the whole state (SNAPSHOT) without restarting anything. The results
-- rank every competitor (shared/Standings); the top three take the podium.
local types = require("@moonbase/types")
local Rules = require("./Rules")

local C = Rules.CONFIG

export type Context = {
	players: () -> {types.Player},
	award: (player: types.Player, starlights: number) -> (),
	send: (players: {types.Player}?, ...types.Value) -> (),
	clock: () -> number,
	startsIn: () -> number,
	identity: (player: types.Player) -> { name: string, outfit: {number}? }?,
	random: () -> number,
}
export type Round = {
	start: () -> (),
	join: (player: types.Player) -> (),
	leave: (player: types.Player) -> (),
	receive: (player: types.Player, kind: unknown, a: unknown, b: unknown, c: unknown) -> (),
	update: (dt: number) -> (),
	finish: () -> (),
}

type Competitor = {
	player: types.Player, -- the latest connection
	name: string, outfit: {number}?,
	seat: number,
	score: number, reachedAt: number,
	reloadUntil: number,
	sequence: number, -- the last shot sequence seen
	connected: boolean,
}

return {
	new = function(context: Context): Round
		local startsAt = context.clock() + context.startsIn()
		local endsAt = startsAt + C.DURATION
		local competitors: {[number]: Competitor} = {} -- by account id
		local seated: {Competitor} = {} -- by seat
		local ids: {number} = {}
		local byId: {[number]: types.Player} = {}
		for _, player in context.players() do
			if not byId[player.player_id] then
				byId[player.player_id] = player
				table.insert(ids, player.player_id)
			end
		end
		table.sort(ids)
		for seat, id in ids do
			local player = byId[id]
			local identity = context.identity(player)
			local c: Competitor = { player = player, name = if identity then identity.name else "Player " .. id,
				outfit = if identity then identity.outfit else nil, seat = seat, score = 0, reachedAt = startsAt,
				reloadUntil = 0, sequence = 0, connected = true }
			competitors[id] = c
			seated[seat] = c
		end
		-- The field's pace, fixed for the round from the roster's size.
		local count = #seated
		local cap = Rules.cap(count)
		local clouds: {[number]: Rules.Cloud} = {} -- every cloud announced, by id
		local claimed: {[number]: boolean} = {}
		local nextId, nextSpawn = 1, startsAt
		local events = 0
		local started, over = false, false

		-- Clouds still up at [at].
		local function live(at: number): {Rules.Cloud}
			local out: {Rules.Cloud} = {}
			for id, cloud in clouds do
				if not claimed[id] and cloud.expiresAt > at then table.insert(out, cloud) end
			end
			return out
		end

		-- Announces a new cloud showing at [at], if it fits.
		local function spawn(at: number): boolean
			local others = live(at)
			if #others >= cap then return false end
			local cloud = Rules.cloud(nextId, at, at - startsAt, others, context.random)
			if not cloud then return false end
			nextId += 1
			clouds[cloud.id] = cloud
			context.send(nil, Rules.SPAWN, Rules.cloudsValue({cloud}))
			return true
		end

		local function snapshot(player: types.Player): types.Value
			local now = context.clock()
			local list: {Rules.Player} = {}
			for seat, c in seated do
				table.insert(list, { player = c.player.player_id, session = c.player.session_id, seat = seat, name = c.name,
					outfit = c.outfit, score = c.score, reloadUntil = c.reloadUntil, connected = c.connected })
			end
			local mine = competitors[player.player_id]
			return Rules.snapshotValue({ version = Rules.VERSION, startsAt = startsAt, endsAt = endsAt, serverNow = now,
				players = list, clouds = live(now), lastSequence = if mine and mine.player == player then mine.sequence else 0,
				lastEvent = events, over = over })
		end

		local function shoot(c: Competitor, sequence: number, id: number, claimedAt: number?)
			-- Each sequence once: a retransmission never costs a second reload.
			if sequence <= c.sequence then return end
			c.sequence = sequence
			local now = context.clock()
			local at = if claimedAt then math.clamp(claimedAt, now - C.MAX_COMPENSATION, now) else now
			local cloud = clouds[id]
			-- Never announced (or made up), out of play, or still reloading: nothing happens.
			if over or not cloud or at < startsAt or at >= endsAt or at < c.reloadUntil - C.RELOAD_SLACK then
				context.send({c.player}, Rules.REJECT, sequence)
				return
			end
			c.reloadUntil = at + C.RELOAD
			local taken = not claimed[id] and at >= cloud.spawnAt and at < cloud.expiresAt
			local delta = 0
			if taken then
				claimed[id] = true
				delta = Rules.VALUES[cloud.kind]
				c.score += delta
				c.reachedAt = at
			end
			events += 1
			context.send(nil, Rules.SHOT, Rules.shotValue({ event = events, sequence = sequence, seat = c.seat, cloud = id,
				claimed = taken, reason = if taken then "" elseif claimed[id] then "claimed" else "expired",
				delta = delta, total = c.score, at = at, reloadUntil = c.reloadUntil }))
		end

		context.send(nil, Rules.SNAPSHOT, snapshot({ session_id = 0, player_id = -1, isActive = true } :: any))

		return {
			start = function()
				started = true
			end,
			update = function(_dt: number)
				if not started or over then return end
				local now = context.clock()
				-- The first clouds together, then one every interval while there is room.
				if nextId == 1 then
					for _ = 1, C.FIRST do spawn(startsAt + C.LEAD) end
					nextSpawn = startsAt + Rules.interval(count, context.random())
				end
				while nextSpawn - C.LEAD <= now and nextSpawn < endsAt do
					spawn(nextSpawn)
					nextSpawn += Rules.interval(count, context.random())
				end
			end,
			join = function(player: types.Player)
				local c = competitors[player.player_id]
				-- A competitor back from a disconnection carries on in their seat.
				if c then c.player, c.connected = player, true end
				context.send({player}, Rules.SNAPSHOT, snapshot(player))
				if c then
					for _, other in seated do
						if other.connected and other ~= c then context.send({other.player}, Rules.SNAPSHOT, snapshot(other.player)) end
					end
				end
			end,
			leave = function(player: types.Player)
				local c = competitors[player.player_id]
				if not c or c.player ~= player then return end
				c.connected = false
				for _, other in seated do
					if other.connected then context.send({other.player}, Rules.SNAPSHOT, snapshot(other.player)) end
				end
			end,
			receive = function(player: types.Player, kind: unknown, a: unknown, b: unknown, cv: unknown)
				if kind == Rules.SYNC then
					if type(a) == "number" and a == a then context.send({player}, Rules.SYNC, a, Rules.ms(context.clock())) end
					return
				end
				if kind ~= Rules.SHOOT then return end
				local c = competitors[player.player_id]
				if not c or c.player ~= player then return end
				local sequence, id, at = Rules.shoot(a, b, cv)
				if sequence and id then shoot(c, sequence, id, at) end
			end,
			finish = function()
				if over then return end
				over = true
				local scores: {Rules.Score} = {}
				for _, c in seated do
					table.insert(scores, { player = c.player.player_id, name = c.name, score = c.score, reachedAt = c.reachedAt })
				end
				local standings: {Rules.Standing} = {}
				for place, s in Rules.rank(scores) do
					local starlights = if place <= Rules.PLACES then Rules.AWARDS[place] or 0 else 0
					table.insert(standings, { player = s.player, name = s.name, score = s.score, place = place, starlights = starlights })
					local c = competitors[s.player]
					-- Prizes go to winners still here to receive them.
					if starlights > 0 and c.connected then context.award(c.player, starlights) end
				end
				context.send(nil, Rules.RESULTS, Rules.standingsValue(standings))
			end,
		}
	end,
}
