--!strict
--@client
-- Blast Mining on each player's client (see Rules and Round). It keeps the
-- round as the server tells it, a clock synced to the server's, and the
-- feedback the Stage draws; it never decides a score.
--
-- Clock: client/ServerClock syncs to the server's with SYNC pings. Items fall
-- from their server spawn and strike times, so motion needs no stream of
-- positions.
--
-- A tap swings at once: the pickaxe animates, the swing goes out with its
-- sequence and the tap's server time, and if one of our items is in the
-- window it shatters with its +1/+3/-3 right away (a bomb also shakes us and
-- slows our next swing). The server's SWING for that sequence names the item
-- it really hit, if any, and its HIT the new total: a guess it did not confirm
-- is undone, and a REJECT undoes the swing's guess too. Other miners' swings,
-- hits, explosions and shakes come from the server as they happen.
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

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local frame, changed = foundation.ChangeNotifier(), foundation.ChangeNotifier()
		local clock = ServerClock.new(function(at: number) context.send(Rules.SYNC, at) end)
		local sequence, lastSwing = 0, -math.huge -- our swings: count, and server time of the last
		local slowUntil = 0 -- ours, as confirmed or guessed
		local pending: {[number]: { item: number?, at: number }} = {} -- our unanswered swings
		local music: engine.AudioPlayback? = nil
		local unsubscribers: {() -> ()} = {}
		local seed = 0

		local model: Model = {
			frame = frame, changed = changed, ready = false, startsAt = 0, endsAt = 0, over = false,
			miners = {}, me = nil, items = {}, hit = {}, guessed = {}, swings = {}, shakes = {}, effects = {}, ripples = {},
			standings = nil, reduced = false, haptics = true,
			round = context.round,
			nextIn = context.remaining,
			-- The server's clock now, as best we know it.
			now = function(self: Model): number
				return clock:now()
			end,
			tap = function(self: Model) end,
		}

		local function sound(clip: engine.AudioClip?, volume: number)
			if clip and clip.isValid then game.audio:play({ clip = clip, volume = volume, bus = engine.AudioBus.sfx }) end
		end

		local function haptic()
			if model.haptics then services.HapticFeedback.lightImpact() end
		end

		local function startMusic()
			if music then return end
			local clip = Assets.get().music
			if not clip or not clip.isValid or game.isMinimized() then return end
			music = game.audio:play({ clip = clip, loop = true, volume = 0.35, bus = engine.AudioBus.music })
		end

		local function stopMusic()
			local playing = music
			music = nil
			if playing and playing.isValid then playing:stop() end
		end

		local function effect(stream: number, item: Rules.Item, delta: number)
			seed += 1
			table.insert(model.effects, { stream = stream, kind = item.kind, delta = delta, at = game.clock(), item = item.id,
				x = item.drift, seed = seed })
			if item.kind == "bomb" then model.shakes[stream] = game.clock() end
		end

		local function feedback(item: Rules.Item)
			local kit = Assets.get()
			if item.kind == "bomb" then sound(kit.bomb, 0.9) elseif item.kind == "gem" then sound(kit.gem, 0.7) else sound(kit.rock, 0.6) end
			haptic()
		end

		local function minerOf(stream: number): Rules.Miner?
			return model.miners[stream]
		end

		-- Undoes the early shatter of [item]: it shows again, its feedback goes.
		local function unguess(item: number)
			model.guessed[item] = nil
			for i = #model.effects, 1, -1 do
				if model.effects[i].item == item and model.effects[i].stream == model.me then table.remove(model.effects, i) end
			end
		end

		model.tap = function(self: Model)
			local me = model.me
			if not me or not model.ready or model.over then return end
			local now = model:now()
			if now < model.startsAt or now > model.endsAt then return end
			-- The cooldown, as the server will judge it; taps inside it do nothing.
			if now - lastSwing < Rules.cooldown(now, slowUntil) then return end
			lastSwing = now
			sequence += 1
			local slowed = now < slowUntil
			model.swings[me] = { at = game.clock(), length = if slowed then C.SLOW_SWING else C.SWING }
			if not model.reduced then table.insert(model.ripples, game.clock()) end
			sound(Assets.get().swing, 0.35)
			context.send(Rules.SWING, sequence, Rules.ms(now))
			-- Our own items: shatter the one in the window right away.
			local mine: {Rules.Item} = {}
			for _, item in model.items do
				if item.stream == me and not model.guessed[item.id] then table.insert(mine, item) end
			end
			local target = Rules.target(mine, model.hit, now)
			pending[sequence] = { item = if target then target.id else nil, at = now }
			if target then
				model.guessed[target.id] = sequence
				effect(me, target, Rules.VALUES[target.kind])
				feedback(target)
				if target.kind == "bomb" then slowUntil = math.max(slowUntil, now + C.SLOW) end
			end
		end

		local function applySnapshot(snapshot: Rules.Snapshot)
			model.ready = true
			model.startsAt, model.endsAt, model.over = snapshot.startsAt, snapshot.endsAt, snapshot.over
			-- A first rough offset until the pings refine it.
			clock:seed(snapshot.serverNow)
			table.clear(model.miners)
			local session = context.me()
			model.me = nil
			for _, miner in snapshot.miners do
				model.miners[miner.stream] = miner
				if miner.session == session then
					model.me = miner.stream
					slowUntil = math.max(slowUntil, miner.slowUntil)
				end
			end
			-- A reconnecting client carries on from the server's count.
			sequence = math.max(sequence, snapshot.lastSequence)
			for _, item in snapshot.items do model.items[item.id] = item end
			for _, id in snapshot.hit do model.hit[id] = true end
			changed:notifyListeners()
		end

		local function onSwing(stream: number, swingSequence: number, slowed: boolean, item: number?)
			if stream == model.me then
				local guess = pending[swingSequence]
				pending[swingSequence] = nil
				if guess and guess.item and guess.item ~= item then unguess(guess.item) end
				return
			end
			model.swings[stream] = { at = game.clock(), length = if slowed then C.SLOW_SWING else C.SWING }
		end

		local function onHit(hit: Rules.Hit)
			model.hit[hit.item] = true
			local miner = minerOf(hit.stream)
			if miner then
				miner.score, miner.slowUntil = hit.total, hit.slowUntil
			end
			local item = model.items[hit.item]
			if hit.stream == model.me then
				slowUntil = math.max(slowUntil, hit.slowUntil)
				-- Shown already if we guessed it; otherwise now.
				if not model.guessed[hit.item] and item then effect(hit.stream, item, hit.delta); feedback(item) end
			elseif item then
				effect(hit.stream, item, hit.delta)
			end
			changed:notifyListeners()
		end

		table.insert(unsubscribers, Assets.listen(function() changed:notifyListeners() end))
		table.insert(unsubscribers, game.onMinimizedChanged(function(minimized: boolean)
			-- Silent while the app is away.
			local playing = music
			if playing and playing.isValid then
				if minimized then playing:pause() else playing:resume() end
			end
		end))
		game.preferPacing("smooth")

		return {
			ownHud = true,
			fixedCamera = true,
			receive = function(kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown, e: unknown)
				if kind == Rules.SYNC then
					clock:answer(a, b)
				elseif kind == Rules.SNAPSHOT then
					local snapshot = Rules.snapshot(a)
					if snapshot then applySnapshot(snapshot) end
				elseif kind == Rules.SPAWN then
					local items = Rules.items(a)
					if items then for _, item in items do model.items[item.id] = item end end
				elseif kind == Rules.SWING then
					local stream, swingSequence = a, b
					local slowed, item = d, e
					if type(stream) == "number" and type(swingSequence) == "number" and type(slowed) == "boolean"
						and type(item) == "number" then
						onSwing(stream, swingSequence, slowed, if item > 0 then item else nil)
					end
				elseif kind == Rules.REJECT then
					if type(a) == "number" then
						local guess = pending[a]
						pending[a] = nil
						if guess and guess.item then unguess(guess.item) end
					end
				elseif kind == Rules.HIT then
					local hit = Rules.hit(a)
					if hit then onHit(hit) end
				elseif kind == Rules.RESULTS then
					local standings = Rules.standings(a)
					if standings then
						model.standings, model.over = standings, true
						stopMusic()
						changed:notifyListeners()
					end
				end
				local _ = c
			end,
			update = function(_dt: number)
				clock:update()
				local t = game.clock()
				if model.ready then
					local now = model:now()
					if now >= model.startsAt - 0.2 and not model.over then startMusic() end
					if now > model.endsAt + 0.5 then stopMusic() end
					-- Forget items long gone, and effects that have played.
					for id, item in model.items do
						if item.strikeAt < now - 2 then model.items[id] = nil; model.guessed[id] = nil end
					end
					for i = #model.effects, 1, -1 do
						if t - model.effects[i].at > 0.7 then table.remove(model.effects, i) end
					end
					for i = #model.ripples, 1, -1 do
						if t - model.ripples[i] > 0.24 then table.remove(model.ripples, i) end
					end
				end
				frame:notifyListeners()
			end,
			hud = function()
				return Stage.View({ model = model })
			end,
			dispose = function()
				stopMusic()
				game.preferPacing("auto")
				for _, unsubscribe in unsubscribers do unsubscribe() end
				table.clear(unsubscribers)
				frame:dispose()
				changed:dispose()
			end,
		}
	end,
} :: Minigame.Module
