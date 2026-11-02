--!strict
--@client
-- Starcatchers on each player's client (see Rules and Round). It keeps the
-- nets this player is shown, a clock synced to the server's
-- (client/ServerClock), and leaves every catch and point to the server.
--
-- Your own net is predicted: a press throws it here at once and tells the
-- server, a release recalls it, and it flies and catches in your own stream
-- here as it will on the server. Each update the server sends replaces the
-- prediction (then moved on to now); a refused throw drops it. Points, the
-- streak and the effects of catches, banks and hits come only from the
-- server's updates, once each (by version). Everyone else's net moves on
-- here between their updates by the same physics, without catches.
--
-- Sound: a quiet celestial loop through play; your own catches, banks and
-- satellite hits. Everything goes quiet while the app is minimized, and a
-- held throw is recalled.
local game = require("@moonbase/game")
local engine = require("@moonbase/engine")
local foundation = require("@flutter/foundation")
local services = require("@flutter/services")
local Minigame = require("../../client/Minigame")
local ServerClock = require("../../client/ServerClock")
local Rules = require("./Rules")
local Assets = require("./Assets")
local Stage = require("./Stage")

local C = Rules.CONFIG

type Model = Stage.Model

local function copy(net: Rules.Net): Rules.Net
	local out = table.clone(net)
	out.consumed = table.clone(net.consumed)
	out.struck = table.clone(net.struck)
	return out
end

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local frame, changed = foundation.ChangeNotifier(), foundation.ChangeNotifier()
		local clock = ServerClock.new(function(at: number) context.send(Rules.SYNC, at) end)
		local sequence, throwSequence = 0, 0
		local pointer: number? = nil -- the finger holding the throw
		local auth: Rules.Net? = nil -- our net as the server last said
		local music: engine.AudioPlayback? = nil
		local unsubscribers: {() -> ()} = {}

		local model: Model = {
			frame = frame, changed = changed, ready = false, seed = 0, startsAt = 0, lineup = {}, participants = {},
			me = nil, center = nil, shown = {}, score = 0, streak = 0, effects = {}, standings = nil, reduced = false,
			round = context.round, nextIn = context.remaining,
			now = function(self: Model): number return clock:now() end,
			press = function(self: Model, _pointer: number) end,
			release = function(self: Model, _pointer: number, _cancelled: boolean) end,
		}

		local function sound(clip: engine.AudioClip?, volume: number)
			if clip and clip.isValid and not game.isMinimized() then
				game.audio:play({ clip = clip, volume = volume, bus = engine.AudioBus.sfx })
			end
		end

		local function stopMusic()
			local playing = music
			music = nil
			if playing and playing.isValid then playing:stop() end
		end

		local function elapsed(): number return clock:now() - model.startsAt end

		local function streamOf(id: number): number?
			local pt = model.participants[id]
			return if pt then pt.stream else nil
		end

		-- Our prediction: the server's word, moved on to now in our own stream.
		local function repredict()
			local me = model.me
			local shown = if me then model.shown[me] else nil
			local stream = if me then streamOf(me) else nil
			if not auth or not shown or not stream then return end
			local net = copy(auth)
			Rules.step(net, elapsed(), model.seed, stream)
			shown.net = net
		end

		model.press = function(self: Model, id: number)
			local me = model.me
			local shown = if me then model.shown[me] else nil
			local stream = if me then streamOf(me) else nil
			if not shown or not stream or pointer ~= nil or model.standings then return end
			local now = elapsed()
			if now < 0 or now >= C.DURATION then return end
			pointer = id
			Rules.step(shown.net, now, model.seed, stream)
			Rules.throw(shown.net, now)
			sequence += 1
			throwSequence = sequence
			context.send(Rules.THROW, sequence)
		end

		model.release = function(self: Model, id: number, _cancelled: boolean)
			if id ~= pointer then return end
			pointer = nil
			local me = model.me
			local shown = if me then model.shown[me] else nil
			local now = elapsed()
			if not shown or now < 0 or now >= C.DURATION then return end
			Rules.recall(shown.net, now)
			sequence += 1
			context.send(Rules.RECALL, sequence)
		end

		local function onUpdate(u: Rules.Update)
			local shown = model.shown[u.player]
			local stream = streamOf(u.player)
			if not stream or (shown and u.version <= shown.version) then return end
			if not shown then
				shown = { net = u.net, version = u.version, stream = stream, height = u.net.height, x = Rules.offset(u.net, elapsed()) }
				model.shown[u.player] = shown
			end
			local s = shown :: Stage.Shown
			s.version = u.version
			if u.player == model.me then
				auth = u.net
				model.score, model.streak = u.net.score, u.net.streak
				repredict()
			else
				s.net = u.net
			end
			local e = u.event
			if e then
				table.insert(model.effects, { player = u.player, kind = e.kind, at = game.clock(), height = e.height, item = e.item, delta = e.delta })
				while #model.effects > 24 do table.remove(model.effects, 1) end
				if u.player == model.me then
					local kit = Assets.get()
					if e.kind == "hook" then sound(kit.hook, 0.4)
					elseif e.kind == "bank" then
						sound(kit.bank, 0.5)
						services.HapticFeedback.lightImpact()
					else
						sound(kit.snap, 0.6)
						services.HapticFeedback.lightImpact()
					end
				end
			end
		end

		local function applySnapshot(snap: Rules.Snapshot)
			clock:seed(snap.serverNow)
			model.ready = true
			model.seed, model.startsAt, model.lineup = snap.seed, snap.startsAt, snap.lineup
			table.clear(model.participants)
			local session = context.me()
			model.me = nil
			for _, pt in snap.participants do
				model.participants[pt.player] = pt
				if pt.session == session then model.me = pt.player end
			end
			model.center = model.me or snap.lineup[1]
			sequence = math.max(sequence, snap.lastSequence)
			-- A snapshot is the whole truth: what was shown before goes.
			table.clear(model.shown)
			for _, u in snap.nets do onUpdate(u) end
			Stage.reset()
			changed:notifyListeners()
		end

		table.insert(unsubscribers, Assets.listen(function() changed:notifyListeners() end))
		table.insert(unsubscribers, game.onMinimizedChanged(function(minimized: boolean)
			-- Away: the net comes home and the sound stops; the round goes on.
			if minimized and pointer then model:release(pointer :: number, true) end
			local playing = music
			if playing and playing.isValid then
				if minimized then playing:pause() else playing:resume() end
			end
		end))
		game.preferPacing("smooth")

		return {
			ownHud = true,
			fixedCamera = true,
			receive = function(kind: unknown, a: unknown, b: unknown)
				if kind == Rules.SYNC then
					clock:answer(a, b)
				elseif kind == Rules.SNAPSHOT then
					local snap = Rules.snapshot(a)
					if snap then applySnapshot(snap) end
				elseif kind == Rules.NET then
					local raw = if type(a) == "table" then (a :: {[unknown]: unknown}).player else nil
					local stream = if type(raw) == "number" then streamOf(raw) else nil
					local u = if stream then Rules.update(a, model.seed, stream) else nil
					if u then onUpdate(u) end
				elseif kind == Rules.REJECT then
					-- A throw the server did not take: back to its word.
					if a == throwSequence then repredict() end
				elseif kind == Rules.RESULTS then
					local standings = Rules.standings(a)
					if standings then
						model.standings = standings
						pointer = nil
						stopMusic()
						changed:notifyListeners()
					end
				end
			end,
			update = function(dt: number)
				clock:update()
				if model.ready then
					local now = elapsed()
					local k = if model.reduced then 1 else 1 - math.exp(-dt * 26)
					for id, s in model.shown do
						local stream = if id == model.me then s.stream else nil
						Rules.step(s.net, now, if stream then model.seed else nil, stream)
						s.height += (s.net.height - s.height) * k
						s.x += (Rules.offset(s.net, now) - s.x) * k
					end
					local t = game.clock()
					for i = #model.effects, 1, -1 do
						if t - model.effects[i].at > 1.2 then table.remove(model.effects, i) end
					end
					-- The loop through play, not over the countdown or results.
					if now >= 0 and now < C.DURATION and not model.standings and not music and not game.isMinimized() then
						local clip = Assets.get().music
						if clip and clip.isValid then music = game.audio:play({ clip = clip, loop = true, volume = 0.3, bus = engine.AudioBus.music }) end
					end
				end
				frame:notifyListeners()
			end,
			hud = function()
				return Stage.View({ model = model })
			end,
			dispose = function()
				if pointer then model:release(pointer :: number, true) end
				stopMusic()
				Stage.reset()
				game.preferPacing("auto")
				for _, unsubscribe in unsubscribers do unsubscribe() end
				table.clear(unsubscribers)
				frame:dispose()
				changed:dispose()
			end,
		}
	end,
} :: Minigame.Module
