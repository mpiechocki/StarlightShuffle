--!strict
--@server
-- Blast Mining's authoritative round on the cycle's server (see Rules for the
-- tuning, schedule and wire format; Server hands it the cycle's context).
--
-- When the cycle announces the mini-game (`new`), everyone here becomes a
-- miner, each with a stream numbered in that order; the list is frozen and
-- anyone who arrives later watches. Play starts when the cycle's announcement
-- ends; every stream's items are drawn then, from the server's own random
-- numbers, and stay private: each one is disclosed to everyone (SPAWN) only
-- LEAD seconds before it starts to fall.
--
-- Clients send swing intents, never scores. A swing counts once per sequence,
-- only during play, only after its cooldown (longer while a bomb's slowdown
-- lasts), and at the time the client claims if that is within
-- MAX_COMPENSATION before it arrived (else when it arrived). It hits the
-- nearest unhit item of the swinger's own stream within the hit window, at
-- most one. Rocks and gems add points; a bomb takes 3 (never below zero) and
-- slows that miner's swings until SLOW after the hit. Everyone hears every
-- accepted swing (SWING) and hit (HIT); a refused swing is answered to its
-- sender alone (REJECT).
--
-- A miner who disconnects keeps their stream, score and slowdown; their items
-- pass unhit while they are away, and a reconnection gets the whole state
-- (SNAPSHOT) without restarting anything. The results rank every miner by
-- points, then by who reached their final score first, then by player id;
-- the top three take the podium and its Starlights, if they scored.
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
	receive: (player: types.Player, kind: unknown, a: unknown, b: unknown) -> (),
	update: (dt: number) -> (),
	finish: () -> (),
}

type Miner = {
	player: types.Player, -- the latest connection
	name: string, outfit: {number}?,
	stream: number,
	score: number, reachedAt: number,
	slowUntil: number,
	lastSwing: number?, -- the server time of the last accepted swing
	sequence: number, -- the last swing sequence seen
	connected: boolean,
	items: {Rules.Item},
}

return {
	new = function(context: Context): Round
		local startsAt = context.clock() + context.startsIn()
		local endsAt = startsAt + C.DURATION
		local miners: {[number]: Miner} = {} -- by account id
		local order: {number} = {} -- account ids, by stream
		for _, player in context.players() do
			if not miners[player.player_id] then
				local identity = context.identity(player)
				table.insert(order, player.player_id)
				miners[player.player_id] = { player = player,
					name = if identity then identity.name else "Player " .. player.player_id,
					outfit = if identity then identity.outfit else nil,
					stream = #order, score = 0, reachedAt = startsAt, slowUntil = 0, lastSwing = nil, sequence = 0,
					connected = true, items = {} }
			end
		end
		local hit: {[number]: boolean} = {}
		local pending: {Rules.Item} = {} -- not yet disclosed, by spawn time
		local disclosed: {Rules.Item} = {}
		local events = 0
		local over = false

		for _, id in order do
			local miner = miners[id]
			miner.items = Rules.schedule(miner.stream, startsAt, miner.stream * 100000, context.random)
			for _, item in miner.items do table.insert(pending, item) end
		end
		table.sort(pending, function(a: Rules.Item, b: Rules.Item): boolean return a.spawnAt > b.spawnAt end)

		local function snapshot(player: types.Player): types.Value
			local now = context.clock()
			local list: {Rules.Miner} = {}
			for _, id in order do
				local m = miners[id]
				table.insert(list, { player = id, session = m.player.session_id, stream = m.stream, name = m.name,
					outfit = m.outfit, score = m.score, slowUntil = m.slowUntil, connected = m.connected })
			end
			-- Only items already disclosed, and only those still to come.
			local items: {Rules.Item} = {}
			for _, item in disclosed do
				if not hit[item.id] and item.strikeAt > now - C.HIT_WINDOW then table.insert(items, item) end
			end
			local hits: {number} = {}
			for id in hit do table.insert(hits, id) end
			local mine = miners[player.player_id]
			return Rules.snapshotValue({ startsAt = startsAt, endsAt = endsAt, serverNow = now, miners = list, items = items,
				hit = hits, lastSequence = if mine and mine.player == player then mine.sequence else 0, over = over })
		end

		local function swing(miner: Miner, sequence: number, claimed: number?)
			-- Each sequence once, in order: a repeat or an older one is a duplicate.
			if sequence <= miner.sequence then return end
			miner.sequence = sequence
			local now = context.clock()
			local at = if claimed then math.clamp(claimed, now - C.MAX_COMPENSATION, now) else now
			local last = miner.lastSwing
			if last and at < last then at = last end
			local ready = not last or at - last >= Rules.cooldown(at, miner.slowUntil) - C.COOLDOWN_SLACK
			if over or at < startsAt or at > endsAt or not ready then
				context.send({miner.player}, Rules.REJECT, sequence)
				return
			end
			miner.lastSwing = at
			local slowed = at < miner.slowUntil
			local item = Rules.target(miner.items, hit, at)
			-- The item it struck, or 0 for a miss (item ids start at 100000).
			context.send(nil, Rules.SWING, miner.stream, sequence, Rules.ms(at), slowed, if item then item.id else 0)
			if not item then return end
			hit[item.id] = true
			local before = miner.score
			miner.score = math.max(0, miner.score + Rules.VALUES[item.kind])
			if miner.score ~= before then miner.reachedAt = at end
			if item.kind == "bomb" then miner.slowUntil = at + C.SLOW end
			events += 1
			context.send(nil, Rules.HIT, Rules.hitValue({ event = events, stream = miner.stream, item = item.id, kind = item.kind,
				delta = Rules.VALUES[item.kind], total = miner.score, at = at, slowUntil = miner.slowUntil }))
		end

		local function disclose()
			local now = context.clock()
			local batch: {Rules.Item} = {}
			while #pending > 0 and pending[#pending].spawnAt - C.LEAD <= now do
				local item = table.remove(pending) :: Rules.Item
				table.insert(disclosed, item)
				table.insert(batch, item)
			end
			if #batch > 0 then context.send(nil, Rules.SPAWN, Rules.itemsValue(batch)) end
		end

		context.send(nil, Rules.SNAPSHOT, snapshot({ session_id = 0, player_id = -1, isActive = true } :: any))

		return {
			start = function()
				disclose()
			end,
			update = function(_dt: number)
				if not over then disclose() end
			end,
			join = function(player: types.Player)
				local miner = miners[player.player_id]
				-- A miner back from a disconnection carries on where the round is.
				if miner then miner.player, miner.connected = player, true end
				context.send({player}, Rules.SNAPSHOT, snapshot(player))
				if miner then
					-- Their session changed: everyone's roster says so.
					for _, id in order do
						local other = miners[id]
						if other.connected and other ~= miner then context.send({other.player}, Rules.SNAPSHOT, snapshot(other.player)) end
					end
				end
			end,
			leave = function(player: types.Player)
				local miner = miners[player.player_id]
				if not miner or miner.player ~= player then return end
				miner.connected = false
				for _, id in order do
					local other = miners[id]
					if other.connected then context.send({other.player}, Rules.SNAPSHOT, snapshot(other.player)) end
				end
			end,
			receive = function(player: types.Player, kind: unknown, a: unknown, b: unknown)
				if kind == Rules.SYNC then
					-- Clock sync: echo the client's time with ours.
					if type(a) == "number" and a == a then context.send({player}, Rules.SYNC, a, Rules.ms(context.clock())) end
					return
				end
				if kind ~= Rules.SWING then return end
				local miner = miners[player.player_id]
				if not miner or miner.player ~= player then return end
				local sequence, claimed = Rules.swing(a, b)
				if sequence then swing(miner, sequence, claimed) end
			end,
			finish = function()
				if over then return end
				over = true
				local scores: {Rules.Score} = {}
				for _, id in order do
					local m = miners[id]
					table.insert(scores, { player = id, name = m.name, score = m.score, reachedAt = m.reachedAt })
				end
				local standings: {Rules.Standing} = {}
				for place, s in Rules.rank(scores) do
					-- Only a score above zero wins a podium prize.
					local starlights = if place <= Rules.PLACES and s.score > 0 then Rules.AWARDS[place] or 0 else 0
					table.insert(standings, { player = s.player, name = s.name, score = s.score, place = place, starlights = starlights })
					local miner = miners[s.player]
					-- Awards go to winners still here to receive them.
					if starlights > 0 and miner.connected then context.award(miner.player, starlights) end
				end
				context.send(nil, Rules.RESULTS, Rules.standingsValue(standings))
			end,
		}
	end,
}
