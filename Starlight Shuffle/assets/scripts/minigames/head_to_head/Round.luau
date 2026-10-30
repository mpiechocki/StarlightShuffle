--!strict
--@server
-- Head to Head's authoritative round on the cycle's server (see Rules for the
-- board, the pool and the wire format; Server hands it the cycle's context).
--
-- When the cycle announces the mini-game (`new`), everyone here becomes a
-- participant and the list is frozen: anyone who arrives later watches and
-- plays the next round. The pool, its order and colours are drawn then and sent
-- to everyone with the countdown (SETUP). The reference stays on the server
-- until play starts (START), so nobody can study it early.
--
-- During play the server owns every canvas. A participant's taps arrive in
-- order with a sequence each; a sequence is used once, and a tap counts only
-- while the round is on, the canvas is unfinished and the deadline has not
-- passed. Every tap is answered with that canvas (CANVAS), and everyone hears
-- each participant's progress (PROGRESS). A canvas that matches the reference
-- in all nine cells completes and locks; its finish time is the server's, from
-- the start of play, with a completion sequence to order equal times. Play
-- ends when its time is up or every connected participant has finished.
--
-- A participant who disconnects keeps their canvas (and any finish already
-- validated); if they come back to this cycle before the end they carry on,
-- and the timer never stops for them. The three fastest finishes take the
-- podium and its Starlights (RESULTS).
local types = require("@moonbase/types")
local Rules = require("./Rules")

-- What the round uses of the cycle's context (server/Minigame), so tests can
-- drive it without a server.
export type Context = {
	players: () -> {types.Player},
	award: (player: types.Player, starlights: number) -> (),
	send: (players: {types.Player}?, ...types.Value) -> (),
	clock: () -> number,
	remaining: () -> number,
	startsIn: () -> number,
	identity: (player: types.Player) -> { name: string, outfit: {number}? }?,
	finish: () -> (),
	game: { read duration: number },
}
export type Round = {
	start: () -> (),
	join: (player: types.Player) -> (),
	leave: (player: types.Player) -> (),
	receive: (player: types.Player, kind: unknown, a: unknown, b: unknown) -> (),
	finish: () -> (),
}

type Participant = {
	player: types.Player, -- the latest connection
	name: string,
	canvas: {number},
	sequence: number, -- the last tap sequence taken
	done: boolean, time: number?, completion: number?,
	connected: boolean,
}

local function random(n: number): number
	return math.random(n)
end

return {
	new = function(context: Context): Round
		local participants: {[number]: Participant} = {} -- by account id
		local order: {number} = {} -- account ids, as they were frozen
		local heads: {Rules.Head} = {}
		for _, player in context.players() do
			if not participants[player.player_id] then
				local identity = context.identity(player)
				local name = if identity then identity.name else "Player " .. player.player_id
				participants[player.player_id] = { player = player, name = name, canvas = Rules.empty(), sequence = 0,
					done = false, time = nil, completion = nil, connected = true }
				table.insert(order, player.player_id)
				local head: Rules.Head = { kind = "player", player = player.player_id, name = name,
					outfit = if identity then identity.outfit else nil }
				table.insert(heads, head)
			end
		end
		local pool = Rules.pool(heads, random)
		local reference = Rules.reference(#pool, random)
		local playing, over = false, false
		local playStart = 0
		local completions = 0

		local function setupFor(): Rules.Setup
			local list: {Rules.Participant} = {}
			for _, id in order do
				local p = participants[id]
				table.insert(list, { player = id, session = p.player.session_id, name = p.name })
			end
			return { pool = pool, participants = list, startsIn = context.startsIn(), duration = context.game.duration }
		end

		local function progress(): {Rules.Progress}
			local rows: {Rules.Progress} = {}
			for _, id in order do
				local p = participants[id]
				table.insert(rows, { player = id, matched = if playing or over then Rules.matched(p.canvas, reference) else 0,
					done = p.done, time = p.time, connected = p.connected })
			end
			return rows
		end

		local function sendCanvas(p: Participant)
			if not p.connected then return end
			context.send({p.player}, Rules.CANVAS, Rules.canvasValue({ cells = p.canvas, ack = p.sequence, done = p.done, time = p.time }))
		end

		local function broadcastProgress()
			context.send(nil, Rules.PROGRESS, Rules.progressValue(progress()))
		end

		local function startValue(): any
			return Rules.startValue({ reference = reference, remaining = context.remaining() })
		end

		-- Over once every connected participant has finished (and someone is here).
		local function allDone(): boolean
			local anyone = false
			for _, p in participants do
				if p.connected then
					anyone = true
					if not p.done then return false end
				end
			end
			return anyone
		end

		local function tap(p: Participant, sequence: number, cell: number)
			-- Each sequence once, in order: a repeat or an older one is a duplicate.
			if sequence <= p.sequence then return end
			p.sequence = sequence
			if playing and not over and not p.done and context.remaining() > 0 then
				p.canvas[cell] = Rules.advance(p.canvas[cell], #pool)
				if Rules.matched(p.canvas, reference) == Rules.CELLS then
					completions += 1
					p.done, p.completion = true, completions
					p.time = math.round((context.clock() - playStart) * 1000) / 1000
				end
				broadcastProgress()
			end
			-- Answered even when refused, so the client drops what it guessed.
			sendCanvas(p)
			if p.done and allDone() then context.finish() end
		end

		context.send(nil, Rules.SETUP, Rules.setupValue(setupFor()))
		broadcastProgress()

		return {
			start = function()
				playing, playStart = true, context.clock()
				context.send(nil, Rules.START, startValue())
				for _, p in participants do sendCanvas(p) end
				broadcastProgress()
			end,
			join = function(player: types.Player)
				local p = participants[player.player_id]
				if p then
					-- A participant back from a disconnection carries on.
					p.player, p.connected = player, true
				end
				-- Everyone who comes in hears the round; latecomers watch.
				context.send({player}, Rules.SETUP, Rules.setupValue(setupFor()))
				if playing or over then context.send({player}, Rules.START, startValue()) end
				if p then
					sendCanvas(p)
					-- Their session changed: everyone's participant list says so.
					context.send(nil, Rules.SETUP, Rules.setupValue(setupFor()))
				end
				broadcastProgress()
			end,
			leave = function(player: types.Player)
				local p = participants[player.player_id]
				if not p or p.player ~= player then return end
				p.connected = false
				broadcastProgress()
				if playing and not over and allDone() then context.finish() end
			end,
			receive = function(player: types.Player, kind: unknown, a: unknown, b: unknown)
				if kind ~= Rules.TAP then return end
				local p = participants[player.player_id]
				if not p or p.player ~= player then return end
				local sequence, cell = Rules.tap(a, b)
				if sequence and cell then tap(p, sequence, cell) end
			end,
			finish = function()
				if over then return end
				over, playing = true, false
				local finishes: {Rules.Finish} = {}
				for id, p in participants do
					if p.done and p.time and p.completion then
						table.insert(finishes, { player = id, name = p.name, time = p.time, sequence = p.completion })
					end
				end
				local podium: {Rules.Place} = {}
				for place, finish in Rules.rank(finishes) do
					if place > Rules.PLACES then break end
					local starlights = Rules.AWARDS[place] or 0
					table.insert(podium, { player = finish.player, name = finish.name, time = finish.time,
						place = place, starlights = starlights })
					local p = participants[finish.player]
					-- A finisher who has since left keeps their place; the award goes
					-- to whoever is still here to receive it.
					if p.connected then context.award(p.player, starlights) end
				end
				broadcastProgress()
				context.send(nil, Rules.RESULTS, Rules.resultsValue(podium))
			end,
		}
	end,
}
