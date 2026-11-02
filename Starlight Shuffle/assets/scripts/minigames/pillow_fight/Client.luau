--!strict
--@client
-- Pillow Fight on each player's client (see Rules and Round). It keeps the
-- round as the server tells it (its room's events once each, in order, by
-- number), a clock synced to the server's (client/ServerClock) for the shared
-- schedule and pillow flights, and the local hold, and leaves every decision
-- to the server.
--
-- Throw: a finger (or Space/Enter) down on Throw begins a charge; lifting
-- throws at the target if held MIN_CHARGE (else it is cancelled); a cancelled
-- touch, MAX_CHARGE, a hit, a dodge, minimizing or the end of play drop it.
-- The meter and wind-up show at once; the pillow only flies when the server's
-- throw event arrives. Dodge leans at once and the server decides.
--
-- Aim: tapping a rival only changes the target; a target knocked out (or gone)
-- is replaced by the first standing rival by seat, and nobody moves.
--
-- Sound: the lullaby through the round; only our own accepted throws and
-- dodges, the hits on us, and the warning ring for a pillow about to land on
-- us (once per pillow, not when spawn protection or our dodge covers it, never
-- for a backlog after being away).
local game = require("@moonbase/game")
local engine = require("@moonbase/engine")
local foundation = require("@flutter/foundation")
local services = require("@flutter/services")
local Minigame = require("../../client/Minigame")
local ServerClock = require("../../client/ServerClock")
local Rules = require("./Rules")
local Model = require("./Model")
local Assets = require("./Assets")
local Stage = require("./Stage")

local C = Rules.CONFIG

type Model = Model.Model

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local frame, changed = foundation.ChangeNotifier(), foundation.ChangeNotifier()
		local clock = ServerClock.new(function(at: number) context.send(Rules.SYNC, at) end)
		local sequence, lastEvent = 0, 0
		local pointer: number? = nil -- the finger holding Throw
		local beginSequence, dodgeSequence = 0, 0
		local warned: {[number]: boolean} = {}
		local music: engine.AudioPlayback? = nil
		local unsubscribers: {() -> ()} = {}

		local model: Model = {
			frame = frame, changed = changed, ready = false,
			schedule = Rules.schedule(0, 1), participants = {}, roster = {}, me = nil, room = 1, actors = {}, projectiles = {},
			target = nil, charging = false, chargeStartedAt = 0, dodgeUntil = 0, hits = {}, throws = {}, hurtAt = -math.huge,
			results = nil, lesson = nil, reduced = false, round = context.round, nextIn = context.remaining,
			now = function(self: Model): number return clock:now() end,
			mine = function(self: Model): Rules.Actor?
				local pt = if self.me then self.participants[self.me] else nil
				if not pt or pt.room ~= self.room then return nil end
				local actor = self.actors[pt.seat]
				return if actor and actor.participant == pt.id then actor else nil
			end,
			choose = function(self: Model, _id: number) end,
			press = function(self: Model, _pointer: number) end,
			release = function(self: Model, _pointer: number, _cancelled: boolean) end,
			dodge = function(self: Model) end,
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

		local function playing(): boolean
			return not model.results and Rules.phaseAt(model.schedule, model:now()) == "playing"
		end

		-- Drops our charge; tells the server unless it already dropped it.
		local function dropCharge(tell: boolean)
			if not model.charging then return end
			model.charging, pointer = false, nil
			if tell then
				sequence += 1
				context.send(Rules.CHARGE, sequence, "cancel")
			end
		end

		local function rivalStanding(id: number?): boolean
			if not id or id == model.me then return false end
			for _, actor in model.actors do
				if actor.participant == id then return Rules.active(actor) end
			end
			return false
		end

		-- Keeps a standing target: the first standing rival by seat when needed.
		local function retarget()
			if model.me == nil or rivalStanding(model.target) then return end
			local best: Rules.Actor? = nil
			for _, actor in model.actors do
				if actor.participant ~= model.me and Rules.active(actor) and (not best or actor.seat < best.seat) then best = actor end
			end
			model.target = if best then best.participant else nil
		end

		model.choose = function(self: Model, id: number)
			if not rivalStanding(id) then return end
			model.target = id
			services.HapticFeedback.lightImpact()
		end

		model.press = function(self: Model, id: number)
			local mine = model:mine()
			local now = model:now()
			if not mine or not playing() or not Rules.active(mine) or model.charging or pointer ~= nil then return end
			if now < mine.throwReadyAt or now < mine.stunnedUntil or not model.target then return end
			pointer = id
			model.charging, model.chargeStartedAt = true, game.clock()
			sequence += 1
			beginSequence = sequence
			context.send(Rules.CHARGE, sequence, "begin")
		end

		model.release = function(self: Model, id: number, cancelled: boolean)
			if id ~= pointer or not model.charging then return end
			local held = game.clock() - model.chargeStartedAt
			if cancelled or held < C.MIN_CHARGE or not model.target then
				dropCharge(true)
				return
			end
			model.charging, pointer = false, nil
			sequence += 1
			context.send(Rules.THROW, sequence, model.target :: number)
		end

		model.dodge = function(self: Model)
			local mine = model:mine()
			local now = model:now()
			if not mine or not playing() or not Rules.active(mine) or now < mine.dodgeReadyAt or now < mine.stunnedUntil then return end
			if game.clock() < model.dodgeUntil then return end
			dropCharge(false) -- the server drops it with the dodge
			model.dodgeUntil = game.clock() + C.DODGE_WINDOW
			sequence += 1
			dodgeSequence = sequence
			context.send(Rules.DODGE, sequence)
			services.HapticFeedback.lightImpact()
		end

		local function applySnapshot(s: Rules.Snapshot)
			clock:seed(s.serverNow)
			model.ready = true
			model.schedule = { startsAt = s.startsAt, playAt = s.playAt, endsAt = s.endsAt, rooms = s.rooms }
			table.clear(model.participants)
			model.roster = s.participants
			for _, pt in s.participants do model.participants[pt.id] = pt end
			model.me, model.room = s.me, s.room
			table.clear(model.actors)
			for _, actor in s.actors do model.actors[actor.seat] = actor end
			model.projectiles = s.projectiles
			lastEvent = s.lastEvent
			sequence = math.max(sequence, s.lastSequence)
			-- A charge does not survive a reconnect (the server dropped it too).
			local mine = model:mine()
			if model.charging and not (mine and mine.charging) then model.charging, pointer = false, nil end
			retarget()
			changed:notifyListeners()
		end

		local function onEvent(e: Rules.Event)
			if e.room ~= model.room or e.event <= lastEvent then return end
			lastEvent = e.event
			for _, actor in e.actors do model.actors[actor.seat] = actor end
			local shot = e.projectile
			local t = game.clock()
			if e.kind == "throw" and shot then
				table.insert(model.projectiles, shot)
				table.insert(model.throws, { participant = shot.from, at = t })
				if shot.from == model.me then sound(Assets.get().throw, 0.5) end
			elseif shot then
				for i = #model.projectiles, 1, -1 do
					if model.projectiles[i].id == shot.id then table.remove(model.projectiles, i) end
				end
				warned[shot.id] = nil
				if e.kind == "hit" or e.kind == "ko" then
					table.insert(model.hits, { participant = shot.to, at = t })
					if shot.to == model.me then
						-- Hit: the thud, a tap, a brief flash; the server dropped our charge.
						model.charging, pointer = false, nil
						model.hurtAt = t
						sound(Assets.get().hit, 0.6)
						services.HapticFeedback.lightImpact()
					end
				end
			end
			if e.kind == "dodge" then
				for _, actor in e.actors do
					if actor.participant == model.me then
						model.dodgeUntil = 0
						sound(Assets.get().dodge, 0.35)
					end
				end
			end
			while #model.hits > 24 do table.remove(model.hits, 1) end
			while #model.throws > 24 do table.remove(model.throws, 1) end
			retarget()
		end

		table.insert(unsubscribers, Assets.listen(function() changed:notifyListeners() end))
		table.insert(unsubscribers, game.onMinimizedChanged(function(minimized: boolean)
			-- Away: let go of any charge and go quiet; the round goes on.
			if minimized then dropCharge(true) end
			local playback = music
			if playback and playback.isValid then
				if minimized then playback:pause() else playback:resume() end
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
					if s then applySnapshot(s) end
				elseif kind == Rules.EVENT then
					local e = Rules.event(a)
					if e then onEvent(e) end
				elseif kind == Rules.REJECT then
					-- A refused begin leaves us not charging; a refused dodge stops the lean.
					-- (A refused throw needs nothing: no pillow flies without the server's event.)
					if a == beginSequence and model.charging then model.charging, pointer = false, nil end
					if a == dodgeSequence then model.dodgeUntil = 0 end
				elseif kind == Rules.RESULTS then
					local results = Rules.results(a)
					if results then
						model.results = results
						dropCharge(false)
						stopMusic()
						changed:notifyListeners()
					end
				end
			end,
			update = function(_dt: number)
				clock:update()
				if model.ready then
					local now = model:now()
					local t = game.clock()
					if model.charging then
						local mine = model:mine()
						if not playing() or not mine or not Rules.active(mine) or now < mine.stunnedUntil then
							dropCharge(true)
						elseif t - model.chargeStartedAt > C.MAX_CHARGE then
							dropCharge(true) -- held too long: cancelled, not thrown
						end
					end
					-- Pillows long past their impact (an event we will not see) go.
					for i = #model.projectiles, 1, -1 do
						if now > model.projectiles[i].impactAt + 1 then table.remove(model.projectiles, i) end
					end
					-- The warning ring: a pillow about to land on us, once each.
					local mine = model:mine()
					if mine and playing() then
						for _, shot in model.projectiles do
							local left = shot.impactAt - now
							if shot.to == mine.participant and not warned[shot.id] and left > 0 and left <= C.WARNING
								and Rules.threatens(shot, mine) then
								warned[shot.id] = true
								sound(Assets.get().warning, 0.55)
							end
						end
					end
					if game.isMinimized() then
						-- Nothing queued up to ring later.
						for _, shot in model.projectiles do warned[shot.id] = true end
					end
					-- The lullaby through the round, not over the results.
					if not model.results and not music and not game.isMinimized() then
						local clip = Assets.get().lullaby
						if clip and clip.isValid then music = game.audio:play({ clip = clip, loop = true, volume = 0.3, bus = engine.AudioBus.music }) end
					end
				end
				frame:notifyListeners()
			end,
			hud = function()
				return Stage.View({ model = model })
			end,
			dispose = function()
				dropCharge(true)
				stopMusic()
				table.clear(warned)
				game.preferPacing("auto")
				for _, unsubscribe in unsubscribers do unsubscribe() end
				table.clear(unsubscribers)
				frame:dispose()
				changed:dispose()
			end,
		}
	end,
} :: Minigame.Module
