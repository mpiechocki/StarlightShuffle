--!strict
--@client
-- Star Pass on each player's client (see Rules and Round). It keeps the match
-- as the server tells it (each event once, in order, by its number), a clock
-- synced to the server's (client/ServerClock) and the local hold, and leaves
-- every decision to the server.
--
-- Charging: one finger (or Space) down on the button begins an attempt bound
-- to the star's possession; lifting or a cancelled touch before CHARGE cancels
-- it; held long enough, the completion goes out and the server's CHARGED
-- reveals the PASS buttons. Any change of possession (a pass, a new wave, a
-- burst, a snapshot) drops whatever hold was going, so nothing carries over to
-- a later catch. A pass waits for the server: PASSED moves the star, REJECT
-- re-enables the buttons. The flight is cosmetic, as in the prototype: a copy
-- of the star flies to its new holder; our own pass's flight starts as we tap.
--
-- Sound: one shared warning tick tied to burstAt, faster as it nears (louder
-- while we hold a star), silent between waves and at results; only our own
-- catches and passes, and one burst per batch, make effects. Everything goes
-- quiet while the app is minimized; the match itself goes on.
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
local RETRY = 0.1 -- seconds before an early completion is sent again

type Model = Stage.Model

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local frame, changed = foundation.ChangeNotifier(), foundation.ChangeNotifier()
		local clock = ServerClock.new(function(at: number) context.send(Rules.SYNC, at) end)
		local sequence, attempt, lastEvent = 0, 0, 0
		local pointer: number? = nil -- the finger holding the button
		local holdPossession = 0 -- the possession the current attempt is for
		local retryAt: number? = nil
		local nextTick, tock = 0, false
		local music: engine.AudioPlayback? = nil
		local unsubscribers: {() -> ()} = {}
		local lastBatch = 0

		local model: Model = {
			frame = frame, changed = changed, ready = false, phase = "countdown",
			startsAt = 0, wave = 0, burstAt = 0, nextWaveAt = 0, players = {}, seats = {}, me = nil, stars = {}, batch = nil,
			departures = {}, bursts = {}, flights = {}, charge = "idle", chargeStartedAt = 0, passing = false, standings = nil, reduced = false,
			round = context.round, nextIn = context.remaining,
			now = function(self: Model): number return clock:now() end,
			press = function(self: Model, _pointer: number) end,
			release = function(self: Model, _pointer: number, _cancelled: boolean) end,
			pass = function(self: Model, _target: number) end,
			myStar = function(self: Model): Rules.Star?
				if not self.me then return nil end
				for _, star in self.stars do if star.holder == self.me then return star end end
				return nil
			end,
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

		-- Drops the hold if our star's possession is no longer the one it was for.
		local function reconcileHold()
			local star = model:myStar()
			if star and star.possession == holdPossession then
				if star.charged then model.charge = "charged" end
				return
			end
			if model.charge ~= "idle" then model.charge = "idle" end
			pointer, retryAt, holdPossession = nil, nil, if star then star.possession else 0
			if star and star.charged then model.charge = "charged" end
		end

		local function send(op: string)
			local star = model:myStar()
			if not star then return end
			sequence += 1
			context.send(Rules.CHARGE, sequence, op, star.id, star.possession, attempt)
		end

		model.press = function(self: Model, id: number)
			local star = model:myStar()
			if model.phase ~= "playing" or not star or model.charge ~= "idle" or pointer ~= nil then return end
			if model:now() >= model.burstAt then return end
			pointer, holdPossession = id, star.possession
			attempt += 1
			model.charge, model.chargeStartedAt = "holding", game.clock()
			send("begin")
		end

		model.release = function(self: Model, id: number, _cancelled: boolean)
			if id ~= pointer then return end
			pointer = nil
			-- Let go before it charged: it starts over from nothing.
			if model.charge == "holding" then
				model.charge = "idle"
				send("cancel")
			end
		end

		model.pass = function(self: Model, target: number)
			local star = model:myStar()
			if not star or model.charge ~= "charged" or model.passing or model.phase ~= "playing" then return end
			if not table.find(star.choices, target) then return end
			model.passing = true
			sequence += 1
			context.send(Rules.PASS, sequence, star.id, star.possession, target)
			-- Off it goes at once; the server's PASSED moves the star itself.
			table.insert(model.flights, { star = star.id, from = star.holder, to = target, at = game.clock() })
		end

		local function setStars(stars: {Rules.Star})
			local before = model:myStar()
			model.stars = stars
			reconcileHold()
			local after = model:myStar()
			if after and (not before or before.possession ~= after.possession) then
				-- A catch (or a new wave's star): a soft chime and a tap.
				sound(Assets.get().catch, 0.6)
				services.HapticFeedback.lightImpact()
			end
		end

		local function applySnapshot(s: Rules.Snapshot)
			model.ready = true
			clock:seed(s.serverNow)
			model.phase, model.startsAt, model.wave, model.burstAt, model.nextWaveAt = s.phase, s.startsAt, s.wave, s.burstAt, s.nextWaveAt
			table.clear(model.players)
			table.clear(model.seats)
			local session = context.me()
			model.me = nil
			for _, pl in s.players do
				model.players[pl.player] = pl
				model.seats[pl.seat] = pl.player
				if pl.session == session then model.me = pl.player end
			end
			-- A reconnect carries on from the server's counts; a recap shows only what is left of it.
			sequence = math.max(sequence, s.lastSequence)
			lastEvent = math.max(lastEvent, s.lastEvent)
			if s.batch then
				model.batch = s.batch
				lastBatch = math.max(lastBatch, s.batch.id)
			end
			setStars(s.stars)
			changed:notifyListeners()
		end

		local function onWave(wave: Rules.Wave)
			if wave.event <= lastEvent then return end
			lastEvent = wave.event
			model.phase, model.wave, model.burstAt = "playing", wave.wave, wave.burstAt
			model.passing = false
			setStars(wave.stars)
			changed:notifyListeners()
		end

		local function onPassed(passed: Rules.Passed)
			if passed.event <= lastEvent then return end
			lastEvent = passed.event
			local from = model.players[passed.from]
			if from then from.passes = passed.passes end
			if passed.from == model.me then
				model.passing = false
				sound(Assets.get().pass, 0.5)
			end
			-- Everyone else's passes fly now; ours already flew as we tapped.
			local flown = false
			for _, f in model.flights do
				if f.star == passed.star and f.from == passed.from and f.to == passed.to then flown = true end
			end
			if not flown then table.insert(model.flights, { star = passed.star, from = passed.from, to = passed.to, at = game.clock() }) end
			setStars(passed.stars)
			changed:notifyListeners()
		end

		local function onEliminated(event: number, batch: Rules.Batch)
			if event <= lastEvent or batch.id <= lastBatch then return end
			lastEvent, lastBatch = event, batch.id
			local t = game.clock()
			for _, id in batch.players do
				local pl = model.players[id]
				if pl then pl.alive, pl.eliminatedWave = false, batch.wave end
				model.departures[id] = t
				table.insert(model.bursts, { player = id, at = t })
			end
			while #model.bursts > 40 do table.remove(model.bursts, 1) end
			model.phase, model.batch, model.nextWaveAt = "recap", batch, batch.nextAt
			model.passing = false
			setStars({})
			sound(Assets.get().burst, 0.6)
			changed:notifyListeners()
		end

		table.insert(unsubscribers, Assets.listen(function() changed:notifyListeners() end))
		table.insert(unsubscribers, game.onMinimizedChanged(function(minimized: boolean)
			-- Away: let go of any hold and go quiet; the match goes on.
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
					local s = Rules.snapshot(a)
					if s and s.lastEvent >= lastEvent then applySnapshot(s) end
				elseif kind == Rules.WAVE then
					local wave = Rules.wave(a)
					if wave then onWave(wave) end
				elseif kind == Rules.PASSED then
					local passed = Rules.passed(a)
					if passed then onPassed(passed) end
				elseif kind == Rules.ELIMINATED then
					local batch = Rules.batch(b)
					if type(a) == "number" and batch then onEliminated(a, batch) end
				elseif kind == Rules.CHARGED then
					local c = Rules.charged(a)
					local star = model:myStar()
					if not c or c.attempt ~= attempt or not star or c.possession ~= star.possession then return end
					if c.status == "charged" then
						model.charge = "charged"
					elseif c.status == "rejected" then
						-- Early: the server will take it a moment later. Anything else: start over.
						if c.reason == "early" and model.charge == "waiting" then retryAt = game.clock() + RETRY
						elseif model.charge ~= "charged" then model.charge, pointer = "idle", nil end
					end
				elseif kind == Rules.REJECT then
					model.passing = false
				elseif kind == Rules.RESULTS then
					local standings = Rules.standings(a)
					if standings then
						model.standings, model.phase = standings, "over"
						stopMusic()
						changed:notifyListeners()
					end
				end
			end,
			update = function(_dt: number)
				clock:update()
				local t = game.clock()
				if model.ready then
					local now = model:now()
					-- The hold completes on its own once long enough.
					if model.charge == "holding" and t - model.chargeStartedAt >= C.COMPLETE_AFTER then
						model.charge = "waiting"
						send("complete")
					elseif model.charge == "waiting" and retryAt and t >= retryAt then
						retryAt = nil
						send("complete")
					end
					-- Countdown and recap end on the server's clock, before any message says so.
					if model.phase == "playing" and now >= model.burstAt then
						if model.charge ~= "idle" then model.charge, pointer = "idle", nil end
					end
					-- The warning ticks.
					if model.phase == "playing" and now < model.burstAt and not game.isMinimized() then
						if t >= nextTick then
							local kit = Assets.get()
							tock = not tock
							sound(if tock then kit.tock else kit.tick, if model:myStar() then 0.5 else 0.25)
							nextTick = t + Rules.tickInterval(model.burstAt - now)
						end
					else
						nextTick = 0
					end
					-- Quiet music through the match, not over the results.
					if model.phase ~= "over" and now >= model.startsAt and not music and not game.isMinimized() then
						local clip = Assets.get().music
						if clip and clip.isValid then music = game.audio:play({ clip = clip, loop = true, volume = 0.22, bus = engine.AudioBus.music }) end
					end
					-- Departing avatars go after REMOVE; bursts after BURST.
					local removed = false
					for id, at in model.departures do
						if t - at >= C.REMOVE then model.departures[id] = nil; removed = true end
					end
					for i = #model.bursts, 1, -1 do
						if t - model.bursts[i].at > C.BURST then table.remove(model.bursts, i) end
					end
					for i = #model.flights, 1, -1 do
						if t - model.flights[i].at > C.FLIGHT then table.remove(model.flights, i) end
					end
					if removed then changed:notifyListeners() end
				end
				frame:notifyListeners()
			end,
			hud = function()
				return Stage.View({ model = model })
			end,
			dispose = function()
				if pointer then model:release(pointer :: number, true) end
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
