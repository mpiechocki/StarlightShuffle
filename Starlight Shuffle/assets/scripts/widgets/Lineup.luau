--!strict
--@client
-- The admins' lineup panel, opened by the admin button in the HUD's head: every
-- mini-game in cycle order with a tick box, the one on now and the one up next
-- marked. Ticking includes a mini-game, unticking leaves it out (one always
-- stays in); cycles play only the ticked ones, from their next pick, in every
-- cycle. The server checks that the sender is an admin. A tap on the dimmed
-- scene or the close button shuts it.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local material = require("@icons/material")
local Place = require("../client/Place")
local Games = require("../shared/Games")
local Net = require("../shared/Net")
local Style = require("./Style")

type Props = { read place: Place.Controller }

local function tag(label: string, tint: ui.Color): w.Widget
	return w.Container({margin = p.EdgeInsets.only({left = 8}), padding = p.EdgeInsets.symmetric({horizontal = 8, vertical = 3}),
		decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(999), border = p.Border.all({color = tint, width = 1})}),
		child = Style.text(label, Style.style(11, tint, ui.FontWeight.w800))})
end

local function row(place: Place.Controller, lineup: Net.Lineup, order: number, info: Games.Game, only: boolean): w.Widget
	local on = table.find(lineup.included, info.id) ~= nil
	-- The last one ticked cannot be unticked.
	local locked = on and only
	local children: {w.Widget} = {
		w.SizedBox({width = 26, child = Style.text(tostring(order), Style.style(14, Style.FAINT, ui.FontWeight.w800))}),
		w.Expanded({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = {
			Style.text(info.title, Style.style(15, if on then Style.WHITE else Style.FAINT, ui.FontWeight.w700)),
			Style.text(info.id .. (if info.minPlayers then " · needs " .. info.minPlayers .. " players" else ""),
				Style.style(11, Style.FAINT, ui.FontWeight.w600)),
		}})}),
	}
	if lineup.current == info.id then table.insert(children, tag("Now", Style.GOLD))
	elseif lineup.upNext == info.id then table.insert(children, tag("Next", Style.SKY)) end
	table.insert(children, w.SizedBox({width = 10}))
	table.insert(children, w.Icon({icon = if on then material.check_box_rounded else material.check_box_outline_blank_rounded,
		size = 26, color = if locked then Style.FAINT elseif on then Style.GOLD else Style.HINT}))
	return w.Semantics({key = w.ValueKey({value = "lineup-" .. info.id}), button = true, checked = on,
		label = info.title .. (if on then ", included" else ", left out"), child = w.GestureDetector({
			behavior = r.HitTestBehavior.opaque,
			onTap = if locked then nil else function() place:setIncluded(info.id, not on) end,
			child = w.Container({
				margin = p.EdgeInsets.only({bottom = 6}), padding = p.EdgeInsets.symmetric({horizontal = 12, vertical = 8}),
				constraints = r.BoxConstraints({minHeight = 52}),
				decoration = p.BoxDecoration({color = if on then Style.MINE else Style.RAISED, borderRadius = p.BorderRadius.circular(12)}),
				child = w.Row({children = children}),
			})})})
end

return function(props: Props): w.Widget
	local place = props.place
	local lineup = place.lineup
	if not lineup then return w.SizedBox.shrink({}) end
	local rows: {w.Widget} = {}
	for i, info in Games.list do table.insert(rows, row(place, lineup, i, info, #lineup.included == 1)) end
	local everything = #lineup.included == #Games.list
	return w.Stack({fit = w.StackFit.expand, children = {
		w.GestureDetector({onTap = function() place:openLineup(false) end, child = w.Container({color = Style.SCRIM})}),
		w.SafeArea({child = w.Center({child = w.Padding({padding = p.EdgeInsets.all(20),
			child = w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = 400, maxHeight = 640}),
				child = Style.card(w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
					w.Row({children = {
						w.Icon({icon = material.tune_rounded, size = 22, color = Style.GOLD}),
						w.SizedBox({width = 8}),
						w.Expanded({child = Style.text("Mini-game lineup", Style.style(20, Style.WHITE, ui.FontWeight.w900))}),
						w.GestureDetector({key = w.ValueKey({value = "lineup-close"}), onTap = function() place:openLineup(false) end,
							child = w.Padding({padding = p.EdgeInsets.all(4),
								child = w.Icon({icon = material.close_rounded, size = 24, color = Style.HINT})})}),
					}}),
					w.SizedBox({height = 4}),
					Style.text("Admins only. Cycles play the ticked mini-games, in this order. Changes apply from the next mini-game, in every cycle.",
						Style.style(13, Style.HINT, ui.FontWeight.w600), 4),
					w.SizedBox({height = 12}),
					w.Flexible({child = w.SingleChildScrollView({child = w.Column({mainAxisSize = w.MainAxisSize.min,
						crossAxisAlignment = w.CrossAxisAlignment.stretch, children = rows})})}),
					w.SizedBox({height = 8}),
					w.Center({child = Style.button("Include all", if everything then nil else function()
						place:includeAll()
					end, "lineup-all")}),
				}}), p.EdgeInsets.all(18), 22)})})})}),
	}})
end
