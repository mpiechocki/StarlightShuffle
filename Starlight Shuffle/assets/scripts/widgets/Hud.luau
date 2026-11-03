--!strict
--@client
-- The HUD over the game view, rebuilt whenever client/Place changes.
--
-- Everywhere: your lifetime Starlights (top left), and a notice while a move
-- between places is under way or failed.
-- Lobby: the leaderboard panel
-- (widgets/Leaderboard) when it is open. Back from a mini-game, a summary card
-- says how many Starlights it won you (or that it won you none this time),
-- until tapped away or for a few seconds (client/Place's `earned`). Between mini-games the head says what
-- is up next and drains to it (the lobby's countdown), with a big 3, 2, 1 at
-- the end for those checked in.
-- Cycle: the Pause/Play button in the head (paused, it reads Stay: you sit out
-- the next mini-game when this one ends). Before and during the mini-game the
-- head's middle is the cycle's timer, the same for each one: how long until it
-- starts, then how long is left (client/Place.clock; amber for the last ten
-- seconds). A mini-game that does not draw its own gets the announcement card
-- before it and the results card after it; its own HUD (if any) is under all
-- of it, below the head (GameUi.HEAD).
-- In a mini-game, a chat button beside Pause/Play opens the chat over everything
-- (widgets/LobbyChat), with a count of what was said since it was last open.
-- Admins (either place): a lineup button (in the lobby's head; in a cycle, or
-- while the lobby counts down, under the Starlights pill) opens widgets/Lineup.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local material = require("@icons/material")
local Games = require("../shared/Games")
local Rewards = require("../shared/Rewards")
local Place = require("../client/Place")
local Chat = require("../client/Chat")
local Cosmetics = require("./Cosmetics")
local Style = require("./Style")
local GameUi = require("./GameUi")
local Leaderboard = require("./Leaderboard")
local Lineup = require("./Lineup")

-- How far up the lobby's bottom notices sit: clear of the chat bar (its 12
-- margin and 50 tall card) with a gap.
local CHAT_BAR = 12 + 50 + 12

type Props = { read place: Place.Controller, read chat: Chat.Controller? }
type Fields = { unlisten: (() -> ())?, unwatch: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local function title(place: Place.Controller): string
	local round = place.round
	local info = Games.get(if round then round.game else nil)
	if info and round and round.phase == "break" then return "Up next: " .. info.title end
	return if info then info.title else "Mini-games"
end

-- The last seconds of the timer, and of a break, stand out.
local URGENT = 10
local AMBER = Style.color(0xffffc46b)

local function phaseLine(place: Place.Controller): string
	local round = place.round
	if not round then return "Waiting for players" end
	local here = round.players or 0
	if round.phase == "waiting" then
		return if place:remaining() > 0 then "Starting soon…" else "Waiting for everyone to arrive…"
	end
	local left = Style.clock(place:remaining())
	if round.phase == "break" then
		local more = Games.MIN_PLAYERS - here
		if more > 0 then return "Needs " .. more .. " more checked in · " .. left end
		if place.ready then return "Starts in " .. left .. " · you're in" end
		return "Starts in " .. left .. " · tap the arcade"
	end
	if round.phase == "intro" then return "Starts in " .. left end
	if round.phase == "playing" then return left .. " left" end
	return "Back to the lobby in " .. left
end

-- Pause (leave once this mini-game ends), or once pressed, Stay: a gold pill
-- that says the way out is taken and takes it back.
local function pauseButton(place: Place.Controller): w.Widget
	if not place.paused then
		return Style.roundButton(material.pause_rounded, function() place:togglePause() end, false, "pause-play")
	end
	return w.GestureDetector({key = w.ValueKey({value = "pause-play"}), onTap = function() place:togglePause() end,
		child = w.Container({height = 52, padding = p.EdgeInsets.only({left = 14, right = 18}),
			decoration = p.BoxDecoration({color = Style.GOLD, borderRadius = p.BorderRadius.circular(999),
				boxShadow = {p.BoxShadow({color = Style.SHADOW, blurRadius = 10, offset = ui.Offset({dx = 0, dy = 3})})}}),
			child = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
				w.Icon({icon = material.play_arrow_rounded, size = 26, color = Style.INK}),
				w.SizedBox({width = 4}),
				Style.text("Stay", Style.style(16, Style.INK, ui.FontWeight.w800)),
			}})})})
end

-- The head's card: what is on or coming, a line under it, and (counting
-- down) a bar draining to it.
local function headCard(place: Place.Controller, status: string, gold: boolean, counting: boolean): w.Widget
	local lines: {w.Widget} = {
		Style.text(title(place), Style.style(17, Style.WHITE, ui.FontWeight.w800), 1, ui.TextAlign.center),
		w.SizedBox({height = 2}),
		Style.text(status, Style.style(13, if gold then Style.GOLD else Style.HINT, ui.FontWeight.w600), 1, ui.TextAlign.center),
	}
	if counting then
		local left = place:remaining()
		table.insert(lines, w.SizedBox({height = 7}))
		table.insert(lines, w.ClipRRect({borderRadius = p.BorderRadius.circular(2), child = w.Container({height = 4,
			color = Style.LINE, alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({
				widthFactor = math.clamp(left / Games.BREAK, 0, 1),
				child = w.Container({color = if left <= 3 then AMBER else Style.GOLD})})})}))
	end
	return Style.card(w.Column({mainAxisSize = w.MainAxisSize.min, children = lines}),
		p.EdgeInsets.symmetric({horizontal = 18, vertical = 10}), 16)
end

-- The head of the cycle's HUD while its mini-game is not on (the group
-- landing, or on the way back): what is on, and the Pause/Play button.
local function cycleHead(place: Place.Controller): w.Widget
	local paused = place.paused
	local status = if place.moving then "Heading back to the lobby…"
		elseif paused then "Sitting out the next mini-game"
		else phaseLine(place)
	return headCard(place, status, paused, false)
end

-- Whether the lobby is counting down to the next mini-game.
local function countingDown(place: Place.Controller): boolean
	local round = place.round
	return place.place == "lobby" and round ~= nil and round.phase == "break"
end

-- The cycle's timer, centred in the head: how long until the mini-game starts,
-- then how long is left of it, with a bar draining over its span. The same
-- for every mini-game.
local function timer(place: Place.Controller): w.Widget?
	local clock = place:clock()
	if not clock then return nil end
	local whole = math.max(0, math.ceil(clock.seconds))
	local urgent = not clock.starting and whole <= URGENT
	local tint = if urgent then AMBER else Style.WHITE
	local label = if place.moving then "Heading to the lobby"
		elseif place.paused then "Then sitting out"
		elseif clock.starting then "Starts in" else "Time left"
	return w.IgnorePointer({child = w.SafeArea({child = w.Padding({padding = p.EdgeInsets.only({top = 12}),
		child = w.Align({alignment = p.Alignment.topCenter, child = w.Container({key = w.ValueKey({value = "cycle-timer"}),
			width = 128, height = 52, padding = p.EdgeInsets.symmetric({horizontal = 14}),
			decoration = p.BoxDecoration({color = Style.SURFACE, borderRadius = p.BorderRadius.circular(18),
				border = p.Border.all({color = if urgent then AMBER else Style.LINE, width = if urgent then 1.5 else 1})}),
			child = w.Column({mainAxisAlignment = w.MainAxisAlignment.center, children = {
				Style.text(string.upper(label), Style.style(9, if place.paused or place.moving then Style.GOLD else Style.HINT,
					ui.FontWeight.w800, 1.2), 1, ui.TextAlign.center),
				w.Row({mainAxisAlignment = w.MainAxisAlignment.center, children = {
					w.Icon({icon = material.timer_rounded, size = 17, color = tint}),
					w.SizedBox({width = 5}),
					Style.text(string.format("%d:%02d", whole // 60, whole % 60), Style.style(21, tint, ui.FontWeight.w900, -0.4)),
				}}),
				w.ClipRRect({borderRadius = p.BorderRadius.circular(2), child = w.Container({height = 3, color = Style.LINE,
					alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({
						widthFactor = math.clamp(clock.seconds / math.max(1, clock.total), 0, 1),
						child = w.Container({color = if urgent then AMBER else Style.GOLD})})})}),
			}})})})})})})
end

local function introCard(place: Place.Controller): w.Widget?
	local round = place.round
	local info = Games.get(if round then round.game else nil)
	if not round or round.phase ~= "intro" or not info then return nil end
	return Style.card(w.Column({mainAxisSize = w.MainAxisSize.min, children = {
		Style.text("Up next", Style.style(13, Style.GOLD, ui.FontWeight.w700), 1, ui.TextAlign.center),
		w.SizedBox({height = 4}),
		Style.text(info.title, Style.style(26, Style.WHITE, ui.FontWeight.w900), 1, ui.TextAlign.center),
		w.SizedBox({height = 6}),
		Style.text(info.blurb, Style.style(14, Style.HINT), 2, ui.TextAlign.center),
		w.SizedBox({height = 12}),
		Style.text(Style.clock(place:remaining(), true), Style.style(40, Style.GOLD, ui.FontWeight.w900), 1, ui.TextAlign.center),
	}}), p.EdgeInsets.symmetric({horizontal = 28, vertical = 20}), 22)
end

local function resultsCard(place: Place.Controller): w.Widget?
	local round, results = place.round, place.results
	if not round or round.phase ~= "results" or not results then return nil end
	local info = Games.get(results.game)
	local rows: {w.Widget} = {
		Style.text((if info then info.title else "Mini-game") .. " results", Style.style(18, Style.WHITE, ui.FontWeight.w800), 1, ui.TextAlign.center),
		w.SizedBox({height = 10}),
	}
	for i, row in results.rows do
		if i > 8 then break end
		table.insert(rows, w.Padding({padding = p.EdgeInsets.symmetric({vertical = 3}), child = w.Row({children = {
			w.SizedBox({width = 24, child = Style.text(tostring(i), Style.style(14, Style.FAINT, ui.FontWeight.w700))}),
			w.Expanded({child = Style.text(row.name, Style.style(15, Style.WHITE, ui.FontWeight.w600))}),
			w.Icon({icon = material.star_rounded, size = 16, color = Style.GOLD}),
			w.SizedBox({width = 4}),
			Style.text("+" .. Style.count(row.starlights), Style.style(15, Style.GOLD, ui.FontWeight.w800)),
		}})}))
	end
	if #results.rows == 0 then
		table.insert(rows, Style.text("Nobody earned Starlights this time.", Style.style(14, Style.HINT), 2, ui.TextAlign.center))
	end
	return w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = 320}), child = Style.card(
		w.Column({mainAxisSize = w.MainAxisSize.min, children = rows}), p.EdgeInsets.all(18), 20)})
end

-- Back in the lobby: what the last mini-game won you.
local function summaryCard(place: Place.Controller): w.Widget?
	local earned = place.earned
	if place.place ~= "lobby" or not earned or not earned.shownAt then return nil end
	local info = Games.get(earned.game)
	local won = earned.starlights > 0
	local places = Rewards.PLACES
	local rows: {w.Widget} = {
		Style.text(string.upper((if info then info.title else "Mini-game") .. " complete"), Style.style(12, Style.HINT, ui.FontWeight.w800, 1.2), 1, ui.TextAlign.center),
		w.SizedBox({height = 14}),
		w.Row({mainAxisAlignment = w.MainAxisAlignment.center, children = {
			w.Opacity({opacity = if won then 1 else 0.45, child = Cosmetics.icon("starlight", 40)}),
			w.SizedBox({width = 10}),
			Style.text(if won then "+" .. Style.count(earned.starlights) else "0",
				Style.style(40, if won then Style.GOLD else Style.FAINT, ui.FontWeight.w900, -0.5)),
		}}),
		w.SizedBox({height = 6}),
		Style.text(if won then (if earned.starlights == 1 then "Starlight won" else "Starlights won") else "No Starlights this time",
			Style.style(17, Style.WHITE, ui.FontWeight.w800), 1, ui.TextAlign.center),
		w.SizedBox({height = 6}),
		Style.text(if won then "Spend them in the shop, or keep climbing the leaderboard."
			else string.format("Score and finish in the top three to win %d, %d or %d.", places[1], places[2], places[3]),
			Style.style(13, Style.HINT, ui.FontWeight.w600), 2, ui.TextAlign.center),
	}
	if place.starlights then
		table.insert(rows, w.SizedBox({height = 12}))
		table.insert(rows, Style.text("Your Starlights: " .. Style.count(place.starlights), Style.style(13, Style.WHITE, ui.FontWeight.w700), 1, ui.TextAlign.center))
	end
	table.insert(rows, w.SizedBox({height = 16}))
	table.insert(rows, w.GestureDetector({key = w.ValueKey({value = "summary-close"}), onTap = function() place:dismissEarned() end,
		child = w.Container({height = 44, alignment = p.Alignment.center,
			decoration = p.BoxDecoration({color = Style.GOLD, borderRadius = p.BorderRadius.circular(999)}),
			child = Style.text("Continue", Style.style(15, Style.INK, ui.FontWeight.w800))})}))
	return w.Center({child = w.Padding({padding = p.EdgeInsets.all(24), child = w.ConstrainedBox({
		constraints = r.BoxConstraints({maxWidth = 320}), child = w.GestureDetector({key = w.ValueKey({value = "summary"}),
			onTap = function() place:dismissEarned() end,
			child = Style.card(w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = rows}),
				p.EdgeInsets.fromLTRB(22, 20, 22, 20), 22)})})})})
end

local function notice(place: Place.Controller): w.Widget?
	local text = if place.moving then (if place.place == "lobby" then "Heading to the mini-games…" else "Heading back to the lobby…")
		elseif place.failed == "busy" then "Hold on, still on the way…"
		elseif place.failed == "full" then "Every mini-game is full. Try again in a moment."
		elseif place.failed then "That didn't work. Try again in a moment."
		elseif not place:online() then "Connecting…"
		else nil
	if not text then return nil end
	return Style.card(Style.text(text, Style.style(15, if place.failed then Style.ERROR else Style.WHITE, ui.FontWeight.w700), 2, ui.TextAlign.center),
		p.EdgeInsets.symmetric({horizontal = 18, vertical = 12}), 16)
end

-- The admins' lineup button: in the lobby's head, before the leaderboard.
local function adminButton(place: Place.Controller, head: {w.Widget})
	if not place.lineup then return end
	table.insert(head, Style.roundButton(material.tune_rounded, function() place:openLineup(true) end, place.lineupOpen, "lineup"))
	table.insert(head, w.SizedBox({width = 10}))
end

-- In a cycle (and while the lobby counts down), a smaller one under the
-- Starlights pill: the mini-games keep that edge clear of their own top panels.
local function cycleAdminButton(place: Place.Controller): w.Widget
	return w.SafeArea({child = w.Padding({padding = p.EdgeInsets.only({top = 12 + 52 + 8, left = 12 + 4}),
		child = w.Align({alignment = p.Alignment.topLeft, child = w.GestureDetector({key = w.ValueKey({value = "lineup"}),
			onTap = function() place:openLineup(true) end,
			child = w.Container({width = 38, height = 38,
				decoration = p.BoxDecoration({color = if place.lineupOpen then Style.GOLD else Style.SURFACE, shape = p.BoxShape.circle,
					border = p.Border.all({color = if place.lineupOpen then Style.GOLD else Style.LINE, width = 1.5})}),
				child = w.Icon({icon = material.tune_rounded, size = 21, color = if place.lineupOpen then Style.INK else Style.WHITE})})})})})})
end

-- In a mini-game, the chat button beside Pause/Play, with the unread count.
-- (widgets/LobbyChat's close button takes its place while the chat is open.)
local CHAT_BUTTON = 44
local function chatButton(chat: Chat.Controller): w.Widget
	local unread = chat.unread
	local children: {w.Widget} = {
		w.Container({width = CHAT_BUTTON, height = CHAT_BUTTON,
			decoration = p.BoxDecoration({color = Style.SURFACE, shape = p.BoxShape.circle,
				border = p.Border.all({color = Style.LINE, width = 1.5})}),
			child = w.Icon({icon = material.chat_bubble_rounded, size = 21, color = Style.WHITE})}),
	}
	if unread > 0 then
		table.insert(children, w.Positioned({top = -4, right = -6, child = w.Container({
			constraints = r.BoxConstraints({minWidth = 18}), height = 18, padding = p.EdgeInsets.symmetric({horizontal = 5}),
			alignment = p.Alignment.center,
			decoration = p.BoxDecoration({color = Style.GOLD, borderRadius = p.BorderRadius.circular(9)}),
			child = Style.text(if unread > 9 then "9+" else tostring(unread), Style.style(11, Style.INK, ui.FontWeight.w900))})}))
	end
	return w.GestureDetector({key = w.ValueKey({value = "chat-open"}), onTap = function() chat:setOpen(true) end,
		child = w.Opacity({opacity = if chat.open then 0 else 1, child = w.Stack({clipBehavior = ui.Clip.none, children = children})})})
end

local function build(place: Place.Controller, chat: Chat.Controller?): w.Widget
	local layers: {w.Widget} = {}
	local inCycle = place.place == "cycle"
	if inCycle then
		local own = place:minigameHud()
		if own then table.insert(layers, own) end
	end
	-- The head: Starlights on the left, then the cycle's timer (centred, its own
	-- layer) or round, and Pause/Play; or in the lobby the leaderboard (also on
	-- the wall, but often out of view). The Starlights pill is not a button:
	-- taps go through it to the game.
	local head: {w.Widget} = {
		w.IgnorePointer({child = Style.pill(Cosmetics.icon("starlight", 18), if place.starlights then Style.count(place.starlights) else "…")}),
	}
	local clock = if inCycle then timer(place) else nil
	if inCycle and (clock or place:minigameOwnsHud()) then
		-- A mini-game is on: the timer says how long, the mini-game the rest.
		table.insert(head, w.Spacer({}))
	elseif inCycle then
		table.insert(head, w.SizedBox({width = 10}))
		table.insert(head, w.Expanded({child = cycleHead(place)}))
		table.insert(head, w.SizedBox({width = 10}))
	elseif countingDown(place) then
		-- The countdown takes the head's middle; the lineup button goes under the pill.
		table.insert(head, w.SizedBox({width = 10}))
		table.insert(head, w.Expanded({child = headCard(place, phaseLine(place), place.ready, true)}))
		table.insert(head, w.SizedBox({width = 10}))
		table.insert(head, Style.roundButton(material.emoji_events_rounded, function() place:openBoard(true) end, false, "leaderboard"))
	elseif place.place == "lobby" then
		table.insert(head, w.Spacer({}))
		adminButton(place, head)
		table.insert(head, Style.roundButton(material.emoji_events_rounded, function() place:openBoard(true) end, false, "leaderboard"))
	end
	if inCycle then
		if chat then
			table.insert(head, chatButton(chat))
			table.insert(head, w.SizedBox({width = 8}))
		end
		table.insert(head, pauseButton(place))
	end
	table.insert(layers, w.SafeArea({child = w.Padding({padding = p.EdgeInsets.all(12),
		child = w.Align({alignment = p.Alignment.topLeft, child = w.Row({
			crossAxisAlignment = w.CrossAxisAlignment.center, children = head})})})}))
	if clock then table.insert(layers, clock) end
	if (inCycle or countingDown(place)) and place.lineup then table.insert(layers, cycleAdminButton(place)) end
	-- The end of the lobby's countdown: 3, 2, 1 and those checked in go.
	local round = place.round
	if countingDown(place) and round and place.ready and (round.players or 0) >= Games.MIN_PLAYERS
		and place:remaining() <= 3 and place:remaining() > 0 then
		table.insert(layers, GameUi.countdown(math.ceil(place:remaining())))
	end
	local center = if inCycle and place.minigame and not place:minigameOwnsHud() then introCard(place) or resultsCard(place) else nil
	if center then
		table.insert(layers, w.IgnorePointer({child = w.Center({child = w.Padding({padding = p.EdgeInsets.all(24), child = center})})}))
	end
	-- (The lobby's hint pointing at the arcade is widgets/LobbyChat's, under the chat.)
	local bottom = notice(place)
	if bottom then
		-- Above the chat bar while it shows (widgets/LobbyChat).
		local lift = if place.place == "lobby" then CHAT_BAR else 28
		table.insert(layers, w.IgnorePointer({child = w.SafeArea({child = w.Align({alignment = p.Alignment.bottomCenter,
			child = w.Padding({padding = p.EdgeInsets.fromLTRB(16, 0, 16, lift), child = bottom})})})}))
	end
	local summary = summaryCard(place)
	if summary then table.insert(layers, summary) end
	if place.place == "lobby" and place.boardOpen then
		table.insert(layers, Leaderboard({place = place}))
	end
	if place.lineupOpen and place.lineup then
		table.insert(layers, Lineup({place = place}))
	end
	return w.Stack({fit = w.StackFit.expand, children = layers})
end

return define("Hud", {
	createState = function(): Fields return { unlisten = nil, unwatch = nil } end,
	initState = function(self: State)
		local refresh = function()
			if self.mounted then self:setState(function() end) end
		end
		self.unlisten = self.widget.place:listen(refresh)
		local chat = self.widget.chat
		if chat then self.unwatch = chat:watch(refresh) end
	end,
	dispose = function(self: State)
		if self.unlisten then self.unlisten(); self.unlisten = nil end
		if self.unwatch then self.unwatch(); self.unwatch = nil end
	end,
	build = function(self: State, _context: w.BuildContext): w.Widget
		return build(self.widget.place, self.widget.chat)
	end,
})
