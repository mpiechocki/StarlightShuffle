--!strict
--@client
-- The HUD over the game view, rebuilt whenever client/Place changes.
--
-- Everywhere: your lifetime Starlights (top left), and a notice while a move
-- between places is under way or failed.
-- Lobby: a hint pointing at the Start Cycle button, and the leaderboard panel
-- (widgets/Leaderboard) when it is open.
-- Cycle: the head of the HUD shows the mini-game, its phase and time left, and
-- the Pause/Play button: paused, you go back to the lobby when this mini-game
-- ends. The announcement card shows before each mini-game, the results card
-- after it, and the mini-game's own HUD (if any) under all of it.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local material = require("@icons/material")
local Games = require("../shared/Games")
local Place = require("../client/Place")
local Style = require("./Style")
local Leaderboard = require("./Leaderboard")

type Props = { read place: Place.Controller }
type Fields = { unlisten: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local function title(place: Place.Controller): string
	local round = place.round
	local info = Games.get(if round then round.game else nil)
	return if info then info.title else "Mini-games"
end

local function phaseLine(place: Place.Controller): string
	local round = place.round
	if not round or round.phase == "waiting" then return "Waiting for players" end
	local left = Style.clock(place:remaining())
	if round.phase == "intro" then return "Starts in " .. left end
	if round.phase == "playing" then return left .. " left" end
	return "Next mini-game in " .. left
end

-- The head of the cycle's HUD: what is on, and the Pause/Play button.
local function cycleHead(place: Place.Controller): w.Widget
	local paused = place.paused
	local status = if place.moving then "Heading back to the lobby…"
		elseif paused then "Leaving after this mini-game"
		else phaseLine(place)
	return w.Row({crossAxisAlignment = w.CrossAxisAlignment.center, children = {
		w.Expanded({child = Style.card(
			w.Column({mainAxisSize = w.MainAxisSize.min, children = {
				Style.text(title(place), Style.style(17, Style.WHITE, ui.FontWeight.w800), 1, ui.TextAlign.center),
				w.SizedBox({height = 2}),
				Style.text(status, Style.style(13, if paused then Style.GOLD else Style.HINT, ui.FontWeight.w600), 1, ui.TextAlign.center),
			}}), p.EdgeInsets.symmetric({horizontal = 18, vertical = 10}), 16)}),
		w.SizedBox({width = 10}),
		-- Play while staying in the cycle; Pause shows Play once it is pressed.
		Style.roundButton(if paused then material.play_arrow_rounded else material.pause_rounded,
			function() place:togglePause() end, paused, "pause-play"),
	}})
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

local function lobbyHint(place: Place.Controller): w.Widget?
	if place.moving or place.boardOpen then return nil end
	return Style.card(w.Row({mainAxisSize = w.MainAxisSize.min, children = {
		w.Icon({icon = material.star_rounded, size = 18, color = Style.GOLD}),
		w.SizedBox({width = 8}),
		w.Flexible({child = Style.text("Tap the big gold button to start the mini-games", Style.style(14, Style.WHITE, ui.FontWeight.w600), 2)}),
	}}), p.EdgeInsets.symmetric({horizontal = 16, vertical = 10}), 999)
end

local function build(place: Place.Controller): w.Widget
	local layers: {w.Widget} = {}
	local inCycle = place.place == "cycle"
	if inCycle then
		local own = place:minigameHud()
		if own then table.insert(layers, own) end
	end
	-- The head: Starlights on the left, then the cycle's round and Pause/Play,
	-- or in the lobby the leaderboard (also on the wall, but often out of view).
	local head: {w.Widget} = {
		Style.pill(material.star_rounded, if place.starlights then Style.count(place.starlights) else "…", Style.GOLD),
	}
	if inCycle then
		table.insert(head, w.SizedBox({width = 10}))
		table.insert(head, w.Expanded({child = cycleHead(place)}))
	elseif place.place == "lobby" then
		table.insert(head, w.Spacer({}))
		table.insert(head, Style.roundButton(material.emoji_events_rounded, function() place:openBoard(true) end, false, "leaderboard"))
	end
	table.insert(layers, w.SafeArea({child = w.Padding({padding = p.EdgeInsets.all(12),
		child = w.Align({alignment = p.Alignment.topLeft, child = w.Row({
			crossAxisAlignment = w.CrossAxisAlignment.center, children = head})})})}))
	local center = if inCycle then introCard(place) or resultsCard(place) else nil
	if center then
		table.insert(layers, w.IgnorePointer({child = w.Center({child = w.Padding({padding = p.EdgeInsets.all(24), child = center})})}))
	end
	local bottom = notice(place) or (if place.place == "lobby" then lobbyHint(place) else nil)
	if bottom then
		table.insert(layers, w.IgnorePointer({child = w.SafeArea({child = w.Align({alignment = p.Alignment.bottomCenter,
			child = w.Padding({padding = p.EdgeInsets.fromLTRB(16, 0, 16, 28), child = bottom})})})}))
	end
	if place.place == "lobby" and place.boardOpen then
		table.insert(layers, Leaderboard({place = place}))
	end
	return w.Stack({fit = w.StackFit.expand, children = layers})
end

return define("Hud", {
	createState = function(): Fields return { unlisten = nil } end,
	initState = function(self: State)
		self.unlisten = self.widget.place:listen(function()
			if self.mounted then self:setState(function() end) end
		end)
	end,
	dispose = function(self: State)
		if self.unlisten then self.unlisten(); self.unlisten = nil end
	end,
	build = function(self: State, _context: w.BuildContext): w.Widget
		return build(self.widget.place)
	end,
})
