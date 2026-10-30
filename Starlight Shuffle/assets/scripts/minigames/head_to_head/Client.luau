--!strict
--@client
-- Head to Head on each player's client (see Rules and Server). It shows what
-- the server says: the round's pool and participants (SETUP), the countdown,
-- the reference once play starts (START), everyone's progress (PROGRESS) and
-- the podium (RESULTS), drawn by Board.
--
-- A tap shows at once: it is sent with the next sequence and kept pending.
-- Each CANVAS from the server is the truth up to the sequence it names; the
-- screen shows that canvas with the still-pending taps on top. Nothing
-- here decides completion or times. Times count down from what the server
-- sent, on this client's clock.
local game = require("@moonbase/game")
local Minigame = require("../../client/Minigame")
local Rules = require("./Rules")
local Heads = require("./Heads")
local Board = require("./Board")

type Pending = { sequence: number, cell: number }

return {
	new = function(context: Minigame.Context): Minigame.Minigame
		local setup: Rules.Setup? = nil
		local prepEndsAt, playEndsAt = 0, 0 -- game.clock() deadlines
		local reference: {number}? = nil
		local confirmed: {number} = Rules.empty() -- the server's canvas
		local ack = 0 -- the last sequence it took
		local nextSequence = 0
		local pending: {Pending} = {}
		local done, time = false, nil :: number?
		local over = false
		local progress: {[number]: Rules.Progress} = {}
		local podium: {Rules.Place}? = nil
		local shown = -1 -- whole seconds last drawn

		local function size(): number
			return if setup then #setup.pool else 1
		end

		-- Our participant record (by session), or nil when we only watch.
		local function mine(): Rules.Participant?
			local session = context.me()
			if not setup or not session then return nil end
			for _, p in setup.participants do
				if p.session == session then return p end
			end
			return nil
		end

		-- The canvas as shown: the server's, then what we tapped since.
		local function cells(): {number}
			local out = table.clone(confirmed)
			if not done then
				for _, tap in pending do out[tap.cell] = Rules.advance(out[tap.cell], size()) end
			end
			return out
		end

		local function playing(): boolean
			return reference ~= nil and not over and game.clock() < playEndsAt
		end

		local function tap(cell: number)
			if not playing() or done or not mine() then return end
			nextSequence += 1
			table.insert(pending, { sequence = nextSequence, cell = cell })
			context.send(Rules.TAP, nextSequence, cell)
			context.refresh()
		end

		local function clockText(): string
			local left = if reference == nil then prepEndsAt - game.clock() else playEndsAt - game.clock()
			if over then left = 0 end
			local whole = math.max(0, math.ceil(left))
			if reference == nil then return tostring(whole) end
			return string.format("%02d:%02d", whole // 60, whole % 60)
		end

		local function view(): Board.View
			local round = context.round()
			local me = mine()
			local pool = if setup then setup.pool else {}
			local players: {Board.Player} = {}
			local places: {[number]: number} = {}
			for _, place in podium or {} do places[place.player] = place.place end
			if setup then
				local entries: {[number]: Rules.Entry} = {}
				for _, entry in pool do
					local head = entry.head
					if head.kind == "player" then entries[head.player] = entry end
				end
				for _, participant in setup.participants do
					local row = progress[participant.player]
					table.insert(players, { player = participant.player, name = participant.name,
						entry = entries[participant.player], matched = if row then row.matched else 0,
						done = if row then row.done else false, time = if row then row.time else nil,
						connected = if row then row.connected else true, mine = me ~= nil and me.player == participant.player,
						place = places[participant.player] })
				end
			end
			local shownCells = if me then cells() else Rules.empty()
			local phase: "waiting" | "prep" | "play" | "over" = if not setup then "waiting"
				elseif over or (reference and game.clock() >= playEndsAt) then "over"
				elseif reference then "play"
				else "prep"
			return {
				phase = phase, spectating = me == nil, clock = clockText(), pool = pool, reference = reference,
				cells = shownCells,
				matched = if reference and me then Rules.matched(shownCells, reference) else 0,
				done = done, time = time,
				onTap = if me and phase == "play" and not done then tap else nil,
				players = players,
				podium = podium, showPodium = podium ~= nil and round ~= nil and round.phase == "results",
				nextIn = tostring(math.max(0, math.ceil(context.remaining()))) .. "s",
				me = if me then me.player else nil,
			}
		end

		local unlisten = Heads.listen(function() context.refresh() end)

		return {
			ownHud = true,
			fixedCamera = true,
			receive = function(kind: unknown, payload: unknown)
				if kind == Rules.SETUP then
					local parsed = Rules.setup(payload)
					if not parsed then return end
					local first = setup == nil
					setup = parsed
					if first then prepEndsAt = game.clock() + parsed.startsIn end
				elseif kind == Rules.START then
					local parsed = setup and Rules.start(payload, size())
					if not parsed then return end
					reference = parsed.reference
					playEndsAt = game.clock() + parsed.remaining
				elseif kind == Rules.CANVAS then
					local parsed = setup and Rules.canvas(payload, size())
					if not parsed then return end
					confirmed, ack, done, time = parsed.cells, parsed.ack, parsed.done, parsed.time
					-- A fresh client (back after a drop) carries on from the server's count.
					nextSequence = math.max(nextSequence, ack)
					local still: {Pending} = {}
					for _, tap in pending do
						if tap.sequence > ack then table.insert(still, tap) end
					end
					pending = if done then {} else still
				elseif kind == Rules.PROGRESS then
					local rows = Rules.progress(payload)
					if not rows then return end
					table.clear(progress)
					for _, row in rows do progress[row.player] = row end
				elseif kind == Rules.RESULTS then
					local places = Rules.results(payload)
					if not places then return end
					podium, over = places, true
					pending = {}
				else
					return
				end
				context.refresh()
			end,
			update = function(_dt: number)
				-- The clock redraws once a second.
				local left = if reference == nil then prepEndsAt - game.clock() else playEndsAt - game.clock()
				local whole = math.ceil(left)
				if whole ~= shown then
					shown = whole
					context.refresh()
				end
			end,
			hud = function()
				return Board.build(view())
			end,
			dispose = function()
				unlisten()
			end,
		}
	end,
} :: Minigame.Module
