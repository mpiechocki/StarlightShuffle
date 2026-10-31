--!strict
--@client
-- Lucky Shot on each player's client (see Rules and Round). It keeps the round
-- as the server tells it, a clock synced to the server's (client/ServerClock)
-- and the feedback the Stage draws; it never decides a score or a claim.
--
-- Clouds drift from their server spawn and expiry times, so motion needs no
-- stream of positions. A tap on a cloud fires at once: the slingshot kicks,
-- a pebble flies, the reload starts and the cloud dims while the shot is
-- out. Only the server's SHOT says what happened: a claim of ours pops the
-- cloud with its raindrops or lightning, its number and (ours only) its
-- sound; a race lost or a cloud gone just ends the dimming; a REJECT also
-- gives the reload back. Nothing shows twice: each SHOT is handled once, by
-- its event number. Rivals' shots kick their slingshots and pop their clouds,
-- silently.
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
local MAX_BURSTS = 11 -- bursts kept at once (about 120 raindrops at most)

type Model = Stage.Model

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local frame, changed = foundation.ChangeNotifier(), foundation.ChangeNotifier()
		local clock = ServerClock.new(function(at: number) context.send(Rules.SYNC, at) end)
		local sequence = 0
		local confirmedReload = 0 -- the reload the server last gave us
		local lastEvent = 0
		local sequences: {[number]: number} = {} -- our unanswered shot sequence -> cloud id
		local music: engine.AudioPlayback? = nil
		local unsubscribers: {() -> ()} = {}
		local seed = 0

		local model: Model = {
			frame = frame, changed = changed, ready = false, startsAt = 0, endsAt = 0, over = false,
			players = {}, me = nil, clouds = {}, claimed = {}, pending = {}, reloadUntil = 0, fired = {}, shots = {},
			bursts = {}, standings = nil, reduced = false,
			round = context.round,
			nextIn = context.remaining,
			now = function(self: Model): number return clock:now() end,
			shoot = function(self: Model, _cloud: number) end,
		}

		local function sound(clip: engine.AudioClip?, volume: number)
			if clip and clip.isValid then game.audio:play({ clip = clip, volume = volume, bus = engine.AudioBus.sfx }) end
		end

		local function startMusic()
			if music then return end
			local clip = Assets.get().music
			if not clip or not clip.isValid or game.isMinimized() then return end
			music = game.audio:play({ clip = clip, loop = true, volume = 0.3, bus = engine.AudioBus.music })
		end

		local function stopMusic()
			local playing = music
			music = nil
			if playing and playing.isValid then playing:stop() end
		end

		local function burst(cloud: Rules.Cloud, at: number, delta: number, mine: boolean)
			seed += 1
			local x, y = Rules.position(cloud, at)
			table.insert(model.bursts, { kind = cloud.kind, x = x, y = y, at = game.clock(), delta = delta, mine = mine, seed = seed })
			while #model.bursts > MAX_BURSTS do table.remove(model.bursts, 1) end
		end

		model.shoot = function(self: Model, id: number)
			local me = model.me
			if not me or not model.ready or model.over then return end
			local now = model:now()
			if now < model.startsAt or now >= model.endsAt then return end
			-- Reloading: the tap does nothing (no queued shots).
			if now < model.reloadUntil then return end
			sequence += 1
			model.reloadUntil = now + C.RELOAD
			model.pending[id] = sequence
			sequences[sequence] = id
			model.fired[me] = game.clock()
			table.insert(model.shots, { cloud = id, at = game.clock() })
			sound(Assets.get().twang, 0.3)
			context.send(Rules.SHOOT, sequence, id, Rules.ms(now))
		end

		local function applySnapshot(snapshot: Rules.Snapshot)
			model.ready = true
			model.startsAt, model.endsAt, model.over = snapshot.startsAt, snapshot.endsAt, snapshot.over
			clock:seed(snapshot.serverNow)
			table.clear(model.players)
			local session = context.me()
			model.me = nil
			for _, player in snapshot.players do
				model.players[player.seat] = player
				if player.session == session then
					model.me = player.seat
					confirmedReload = player.reloadUntil
					model.reloadUntil = math.max(model.reloadUntil, player.reloadUntil)
				end
			end
			-- A reconnecting client carries on from the server's counts.
			sequence = math.max(sequence, snapshot.lastSequence)
			lastEvent = math.max(lastEvent, snapshot.lastEvent)
			for _, cloud in snapshot.clouds do model.clouds[cloud.id] = cloud end
			changed:notifyListeners()
		end

		local function answered(shotSequence: number)
			local id = sequences[shotSequence]
			sequences[shotSequence] = nil
			if id and model.pending[id] == shotSequence then model.pending[id] = nil end
		end

		local function onShot(shot: Rules.Shot)
			-- Each event once, even if it arrives again.
			if shot.event <= lastEvent then return end
			lastEvent = shot.event
			local player = model.players[shot.seat]
			if player then player.score = shot.total end
			local cloud = model.clouds[shot.cloud]
			local mine = shot.seat == model.me
			if mine then
				answered(shot.sequence)
				confirmedReload = shot.reloadUntil
				model.reloadUntil = math.max(model.reloadUntil, shot.reloadUntil)
			else
				model.fired[shot.seat] = game.clock()
			end
			if shot.claimed and cloud then
				model.claimed[shot.cloud] = true
				burst(cloud, shot.at, shot.delta, mine)
				if mine then
					local kit = Assets.get()
					if cloud.kind == "storm" then sound(kit.thunder, 0.8)
					elseif cloud.kind == "gold" then sound(kit.popGold, 0.7)
					else sound(kit.pop, 0.7) end
					services.HapticFeedback.lightImpact()
				end
			end
			changed:notifyListeners()
		end

		table.insert(unsubscribers, Assets.listen(function() changed:notifyListeners() end))
		table.insert(unsubscribers, game.onMinimizedChanged(function(minimized: boolean)
			-- Silent while the app is away; the round itself goes on.
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
					local snapshot = Rules.snapshot(a)
					if snapshot then applySnapshot(snapshot) end
				elseif kind == Rules.SPAWN then
					local clouds = Rules.clouds(a)
					if clouds then for _, cloud in clouds do model.clouds[cloud.id] = cloud end end
				elseif kind == Rules.SHOT then
					local shot = Rules.shot(a)
					if shot then onShot(shot) end
				elseif kind == Rules.REJECT then
					if type(a) == "number" then
						answered(a)
						-- The server did not take the shot: no reload for it.
						model.reloadUntil = confirmedReload
					end
				elseif kind == Rules.RESULTS then
					local standings = Rules.standings(a)
					if standings then
						model.standings, model.over = standings, true
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
					if now >= model.startsAt - 0.2 and not model.over then startMusic() end
					if now > model.endsAt + 0.5 then stopMusic() end
					-- Forget clouds long gone and effects that have played.
					for id, cloud in model.clouds do
						if cloud.expiresAt < now - 1 then
							model.clouds[id], model.claimed[id], model.pending[id] = nil, nil, nil
						end
					end
					for i = #model.bursts, 1, -1 do
						if t - model.bursts[i].at > 0.9 then table.remove(model.bursts, i) end
					end
					for i = #model.shots, 1, -1 do
						if t - model.shots[i].at > 0.2 then table.remove(model.shots, i) end
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
