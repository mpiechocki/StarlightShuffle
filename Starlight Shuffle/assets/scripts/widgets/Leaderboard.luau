--!strict
--@client
-- The leaderboard panel the lobby's leaderboard button opens: the top players
-- by Starlight balance (what they have to spend), and where you stand. It asks the server each time it
-- opens (client/Place); a tap on the dimmed scene or the close button shuts it.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local m = require("@flutter/material")
local material = require("@icons/material")
local Cosmetics = require("./Cosmetics")
local Place = require("../client/Place")
local Style = require("./Style")
local Net = require("../shared/Net")

type Props = { read place: Place.Controller }

local function row(rank: number, entry: Net.Row): w.Widget
	local tint = if rank == 1 then Style.GOLD elseif rank <= 3 then Style.SKY else Style.FAINT
	return w.Container({
		key = w.ValueKey({value = "row-" .. entry.player}),
		margin = p.EdgeInsets.only({bottom = 6}),
		padding = p.EdgeInsets.symmetric({horizontal = 12, vertical = 9}),
		decoration = p.BoxDecoration({color = Style.RAISED, borderRadius = p.BorderRadius.circular(12)}),
		child = w.Row({children = {
			w.SizedBox({width = 30, child = Style.text(tostring(rank), Style.style(15, tint, ui.FontWeight.w900))}),
			w.Expanded({child = Style.text(entry.name, Style.style(15, Style.WHITE, ui.FontWeight.w600))}),
			Cosmetics.icon("starlight", 17),
			w.SizedBox({width = 4}),
			Style.text(Style.count(entry.starlights), Style.style(15, Style.GOLD, ui.FontWeight.w800)),
		}}),
	})
end

local function body(board: Net.Board?): w.Widget
	if not board then
		return w.Padding({padding = p.EdgeInsets.all(24), child = w.Center({child = w.SizedBox({width = 22, height = 22,
			child = m.CircularProgressIndicator({strokeWidth = 2, color = Style.GOLD})})})})
	end
	if #board.top == 0 then
		return w.Padding({padding = p.EdgeInsets.all(20), child = Style.text(
			"No Starlights yet. Play the mini-games to be first!", Style.style(14, Style.HINT), 3, ui.TextAlign.center)})
	end
	local rows: {w.Widget} = {}
	for i, entry in board.top do table.insert(rows, row(i, entry)) end
	return w.Flexible({child = w.SingleChildScrollView({child = w.Column({mainAxisSize = w.MainAxisSize.min, children = rows})})})
end

return function(props: Props): w.Widget
	local place = props.place
	local board = place.board
	local mine = if board and board.rank then "You're #" .. Style.count(board.rank) .. " with " .. Style.count(board.mine) .. (if board.mine == 1 then " Starlight" else " Starlights")
		elseif board then "Earn Starlights in the mini-games to get on the board"
		else ""
	return w.Stack({fit = w.StackFit.expand, children = {
		w.GestureDetector({onTap = function() place:openBoard(false) end,
			child = w.Container({color = Style.SCRIM})}),
		w.SafeArea({child = w.Center({child = w.Padding({padding = p.EdgeInsets.all(20),
			child = w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = 380, maxHeight = 520}),
				child = Style.card(w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
					w.Row({children = {
						w.Icon({icon = material.emoji_events_rounded, size = 22, color = Style.GOLD}),
						w.SizedBox({width = 8}),
						w.Expanded({child = Style.text("Leaderboard", Style.style(20, Style.WHITE, ui.FontWeight.w900))}),
						w.GestureDetector({key = w.ValueKey({value = "leaderboard-close"}), onTap = function() place:openBoard(false) end,
							child = w.Padding({padding = p.EdgeInsets.all(4),
								child = w.Icon({icon = material.close_rounded, size = 24, color = Style.HINT})})}),
					}}),
					w.SizedBox({height = 4}),
					Style.text(mine, Style.style(13, Style.HINT, ui.FontWeight.w600), 2),
					w.SizedBox({height = 12}),
					body(board),
				}}), p.EdgeInsets.all(18), 22)})})})}),
	}})
end
