--!strict
--@client
-- Head to Head's screen: one portrait column at most 440 wide, centred, over
-- the art room. From the top: the status bar (what is happening and the time),
-- the reference board (or, while the round gets ready, the instructions in its
-- place), your larger canvas with its matched-tile count, and the strip of
-- participants with their progress. When the round ends the podium covers it.
-- Every tile shows an avatar head in that head's own outline colour; there are
-- no numbers, legends or cycle order on screen.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local m = require("@flutter/material")
local es = require("@es/ui")
local game = require("@moonbase/game")
local fonts = require("@fonts/app")
local material = require("@icons/material")
local Appearance = require("../../client/Appearance")
local Rules = require("./Rules")
local Heads = require("./Heads")
local PlayerTag = require("../../widgets/PlayerTag")
local Looks = require("../../client/Looks")
local GameUi = require("../../widgets/GameUi")
local Cosmetics = require("../../widgets/Cosmetics")

local function color(v: number): ui.Color return ui.Color({value = v}) end
local function rgb(v: number, alpha: number): ui.Color return ui.Color({value = alpha * 0x1000000 + v}) end

local PANEL = color(0xc23a2a5c) -- translucent purple
local PANEL_DEEP = color(0xd9302250)
local EDGE = color(0x40ffffff)
local TILE = color(0x40ffffff)
local TILE_EMPTY = color(0x26ffffff)
local WHITE = color(0xffffffff)
local SOFT = color(0xd9f3eaff)
local FAINT = color(0x99f3eaff)
local LILAC = color(0xffd7c6ff)
local GOLD = color(0xffffd166)
local SILVER = color(0xffd9def0)
local BRONZE = color(0xffe0a47a)
local SCRIM = color(0x99140c24)
local MAX_WIDTH = 440
local HUD_TOP = 76 -- the cycle's Starlights and Pause/Play sit above the column
local STRIP = 98

local function style(size: number, colour: ui.Color, weight: ui.FontWeight?, spacing: number?): p.TextStyle
	return p.TextStyle({fontFamily = fonts.lato, fontSize = size, color = colour, fontWeight = weight, letterSpacing = spacing})
end

local function text(data: string, s: p.TextStyle, align: ui.TextAlign?, lines: number?): w.Widget
	return w.Text({data = data, style = s, textAlign = align, maxLines = lines or 1, overflow = w.TextOverflow.ellipsis})
end

local function panel(child: w.Widget, padding: p.EdgeInsets?, deep: boolean?): w.Widget
	return w.Container({
		padding = padding or p.EdgeInsets.all(12),
		decoration = p.BoxDecoration({color = if deep then PANEL_DEEP else PANEL, borderRadius = p.BorderRadius.circular(18),
			border = p.Border.all({color = EDGE, width = 1})}),
		child = child,
	})
end

local function caption(data: string): w.Widget
	return text(string.upper(data), style(11, LILAC, ui.FontWeight.w800, 1.6))
end

-- An avatar head, cropped from its artwork: a player's from their outfit's
-- image (the top of it, where the head and hair are), a library head from its
-- approved crop.
local function headImage(entry: Rules.Entry, size: number): w.Widget
	local head = entry.head
	if head.kind == "library" then
		local texture = Heads.get(head.library)
		if not texture then return w.SizedBox({width = size, height = size}) end
		return w.Image({image = game.image(texture), width = size, height = size, fit = p.BoxFit.cover,
			alignment = p.Alignment.topCenter, filterQuality = ui.FilterQuality.medium})
	end
	local url = Appearance.url(head.outfit or Appearance.STARTER)
	-- The trimmed outfit image is about as wide as the shoulders; showing its
	-- middle 70%, from the top, frames the head with its hair and accessories.
	local wide = size * 1.42
	return w.ClipRect({child = w.SizedBox({width = size, height = size, child = w.OverflowBox({
		alignment = p.Alignment.topCenter, minWidth = wide, maxWidth = wide, minHeight = 0, maxHeight = size * 4,
		child = es.WebImage({url = url, width = wide, fit = p.BoxFit.fitWidth, alignment = p.Alignment.topCenter,
			showLoading = false}),
	})})})
end

-- One tile: a head in its outline colour, or empty.
local function tile(entry: Rules.Entry?, size: number, radius: number, outline: number, onTap: (() -> ())?, key: string): w.Widget
	local inner = size - outline * 2
	local body: w.Widget
	if entry then
		body = w.ClipRRect({borderRadius = p.BorderRadius.circular(math.max(2, radius - outline)),
			child = w.Container({color = rgb(entry.color, 0x40), child = headImage(entry, inner)})})
	else
		body = w.Center({child = w.Icon({icon = material.add_rounded, size = math.min(28, size * 0.22), color = FAINT})})
	end
	local box = w.Container({
		width = size, height = size,
		decoration = p.BoxDecoration({color = if entry then TILE else TILE_EMPTY, borderRadius = p.BorderRadius.circular(radius),
			border = p.Border.all({color = if entry then color(0xff000000 + entry.color) else EDGE, width = if entry then outline else 1})}),
		padding = if entry then nil else p.EdgeInsets.all(0),
		child = body,
	})
	if not onTap then return w.KeyedSubtree({key = w.ValueKey({value = key}), child = box}) end
	return w.GestureDetector({key = w.ValueKey({value = key}), behavior = r.HitTestBehavior.opaque,
		onTapDown = function(_: any) onTap() end, child = box})
end

-- A 3x3 board of [cells] (pool positions, 0 empty) at [side] wide.
local function board(pool: {Rules.Entry}, cells: {number}, side: number, gap: number, onTap: ((number) -> ())?, name: string): w.Widget
	local size = (side - gap * 2) / 3
	local radius = math.max(6, size * 0.12)
	local outline = if size > 60 then 3 else 2
	local rows: {w.Widget} = {}
	for row = 0, 2 do
		local children: {w.Widget} = {}
		for col = 1, 3 do
			local cell = row * 3 + col
			local at = cells[cell] or 0
			local tap = if onTap then function() onTap(cell) end else nil
			table.insert(children, tile(if at > 0 then pool[at] else nil, size, radius, outline, tap, name .. cell))
			if col < 3 then table.insert(children, w.SizedBox({width = gap})) end
		end
		table.insert(rows, w.Row({mainAxisSize = w.MainAxisSize.min, children = children}))
		if row < 2 then table.insert(rows, w.SizedBox({height = gap})) end
	end
	return w.Column({mainAxisSize = w.MainAxisSize.min, children = rows})
end

export type Player = {
	player: number, name: string, entry: Rules.Entry?, matched: number, done: boolean,
	time: number?, connected: boolean, mine: boolean, place: number?,
}
export type View = {
	-- `waiting`: no round for us (not in it, or nothing yet); `prep`: the
	-- countdown; `play`; `over`: play ended.
	phase: "waiting" | "prep" | "play" | "over",
	spectating: boolean,
	pool: {Rules.Entry},
	reference: {number}?,
	cells: {number},
	matched: number,
	done: boolean, time: number?,
	onTap: ((number) -> ())?,
	players: {Player},
	podium: {Rules.Place}?, showPodium: boolean, nextIn: string,
	me: number?, -- our account id, once known
}

-- Where the round is (the cycle's timer in the head shows how long is left).
local function status(view: View): w.Widget
	local label = if view.phase == "prep" then "Get ready"
		elseif view.phase == "play" then (if view.done then "Finished!" elseif view.spectating then "Watching" else "Matching")
		elseif view.phase == "over" then (if view.done then "Finished!" else "Time's up")
		else "Head to Head"
	return panel(w.Row({children = {
		w.Expanded({child = caption(label)}),
	}}), p.EdgeInsets.symmetric({horizontal = 18, vertical = 14}))
end

local function instructions(view: View, height: number): w.Widget
	local lines: {w.Widget} = {
		text("Get ready to match", p.TextStyle({fontFamily = fonts.lato, fontSize = 24, color = WHITE,
			fontWeight = ui.FontWeight.w900, fontStyle = ui.FontStyle.italic}), ui.TextAlign.center),
		w.SizedBox({height = 10}),
	}
	if view.spectating then
		table.insert(lines, text("This round has started without you.", style(15, SOFT, ui.FontWeight.w700), ui.TextAlign.center, 2))
		table.insert(lines, w.SizedBox({height = 4}))
		table.insert(lines, text("You'll play the next one.", style(14, FAINT, ui.FontWeight.w600), ui.TextAlign.center, 2))
	else
		for _, line in { "Tap a tile to change its avatar.", "Match your canvas to the reference." } do
			table.insert(lines, text(line, style(15, SOFT, ui.FontWeight.w700), ui.TextAlign.center, 2))
			table.insert(lines, w.SizedBox({height = 4}))
		end
		table.insert(lines, w.SizedBox({height = 4}))
		table.insert(lines, text("The three fastest completed boards win.", style(14, FAINT, ui.FontWeight.w600), ui.TextAlign.center, 2))
	end
	return w.SizedBox({height = height, child = panel(w.Center({child = w.Column({mainAxisSize = w.MainAxisSize.min, children = lines})}),
		p.EdgeInsets.symmetric({horizontal = 18, vertical = 14}))})
end

local function strip(view: View): w.Widget
	local items: {w.Widget} = {}
	for _, player in view.players do
		local tint = if player.entry then color(0xff000000 + player.entry.color) else EDGE
		local head = if player.entry then w.ClipRRect({borderRadius = p.BorderRadius.circular(8),
			child = headImage(player.entry, 40)}) else w.SizedBox({width = 40, height = 40})
		local badge: w.Widget? = nil
		if player.place then
			local medal = if player.place == 1 then GOLD elseif player.place == 2 then SILVER else BRONZE
			badge = w.Positioned({right = -4, top = -4, child = w.Container({width = 18, height = 18,
				decoration = p.BoxDecoration({color = medal, shape = p.BoxShape.circle}),
				child = w.Center({child = text(tostring(player.place), style(11, color(0xff2b1d44), ui.FontWeight.w900))})})})
		elseif player.done then
			badge = w.Positioned({right = -4, top = -4, child = w.Container({width = 18, height = 18,
				decoration = p.BoxDecoration({color = color(0xff9be38a), shape = p.BoxShape.circle}),
				child = w.Icon({icon = material.check_rounded, size = 13, color = color(0xff1f3a1a)})})})
		end
		local stack: {w.Widget} = {
			w.Container({width = 46, height = 46, decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(10),
				border = p.Border.all({color = tint, width = 2})}), child = w.Center({child = head})}),
		}
		if badge then table.insert(stack, badge) end
		table.insert(items, w.Opacity({key = w.ValueKey({value = "p" .. player.player}), opacity = if player.connected then 1 else 0.45,
			child = w.SizedBox({width = 64, child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
				w.Stack({clipBehavior = ui.Clip.none, children = stack}),
				w.SizedBox({height = 4}),
				-- In their shop look when they wear one (widgets/PlayerTag).
				if Looks.of(player.player) then PlayerTag({player = player.player, name = if player.mine then "you" else player.name,
					size = 10, maxWidth = 64})
				else text(if player.mine then "you" else player.name, style(11, WHITE, ui.FontWeight.w700), ui.TextAlign.center),
				w.SizedBox({height = 3}),
				w.SizedBox({width = 46, child = m.LinearProgressIndicator({value = player.matched / Rules.CELLS, minHeight = 3,
					backgroundColor = TILE_EMPTY, color = tint, borderRadius = p.BorderRadius.circular(2)})}),
			}})})}))
	end
	return panel(w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = {
		w.Row({children = {
			w.Expanded({child = caption("Players")}),
			text(tostring(#view.players), style(11, FAINT, ui.FontWeight.w700)),
		}}),
		w.SizedBox({height = 8}),
		w.SingleChildScrollView({scrollDirection = w.Axis.horizontal, child = w.Row({children = items})}),
	}}), p.EdgeInsets.fromLTRB(14, 10, 14, 10))
end

local function seconds(t: number): string
	return string.format("%.1fs", t)
end

local function podium(view: View): w.Widget?
	local places = view.podium
	if not view.showPodium or not places then return nil end
	local mine: Rules.Place? = nil
	for _, place in places do if place.player == view.me then mine = place end end
	local meRow: Player? = nil
	for _, player in view.players do if player.mine then meRow = player end end
	local headline = if mine then "You made the podium!"
		elseif #places == 0 then "Nobody finished this time"
		elseif meRow and meRow.done then "So close!"
		else "That's a wrap"
	local detail = if meRow and meRow.done and meRow.time then "You matched all 9 tiles in " .. string.format("%.1f", meRow.time) .. " seconds."
		elseif meRow then "You matched " .. meRow.matched .. " of 9 tiles."
		else "Here's who matched fastest."
	local rows: {w.Widget} = {}
	local byPlayer: {[number]: Player} = {}
	for _, player in view.players do byPlayer[player.player] = player end
	for _, place in places do
		local medal = if place.place == 1 then GOLD elseif place.place == 2 then SILVER else BRONZE
		local player = byPlayer[place.player]
		local entry = if player then player.entry else nil
		table.insert(rows, w.Container({
			key = w.ValueKey({value = "podium" .. place.place}),
			margin = p.EdgeInsets.only({bottom = 8}),
			padding = p.EdgeInsets.symmetric({horizontal = 14, vertical = 10}),
			decoration = p.BoxDecoration({color = color(0x33ffffff), borderRadius = p.BorderRadius.circular(14),
				border = p.Border.all({color = EDGE, width = 1})}),
			child = w.Row({children = {
				w.Icon({icon = material.emoji_events_rounded, size = 22, color = medal}),
				w.SizedBox({width = 10}),
				w.Container({width = 38, height = 38, decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(9),
					border = p.Border.all({color = if entry then color(0xff000000 + entry.color) else EDGE, width = 2})}),
					child = if entry then w.ClipRRect({borderRadius = p.BorderRadius.circular(7), child = headImage(entry, 34)}) else nil}),
				w.SizedBox({width = 10}),
				w.Expanded({child = text(if place.player == view.me then "you" else place.name, style(16, WHITE, ui.FontWeight.w800))}),
				text(seconds(place.time), style(14, SOFT, ui.FontWeight.w700)),
				w.SizedBox({width = 10}),
				Cosmetics.icon("starlight", 16),
				w.SizedBox({width = 3}),
				text("+" .. place.starlights, style(14, GOLD, ui.FontWeight.w900)),
			}}),
		}))
	end
	if #places == 0 then
		table.insert(rows, text("No board was completed before the time ran out.", style(14, FAINT), ui.TextAlign.center, 2))
	end
	return w.Stack({fit = w.StackFit.expand, children = {
		w.Container({color = SCRIM}),
		w.Center({child = w.Padding({padding = p.EdgeInsets.all(20), child = w.ConstrainedBox({
			constraints = r.BoxConstraints({maxWidth = 400}),
			child = panel(w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
				w.Center({child = caption("That's a wrap")}),
				w.SizedBox({height = 8}),
				text(headline, p.TextStyle({fontFamily = fonts.lato, fontSize = 26, color = WHITE, fontWeight = ui.FontWeight.w900,
					fontStyle = ui.FontStyle.italic}), ui.TextAlign.center, 2),
				w.SizedBox({height = 6}),
				text(detail, style(14, SOFT, ui.FontWeight.w600), ui.TextAlign.center, 2),
				w.SizedBox({height = 14}),
				-- What it won you (nothing while watching).
				GameUi.earned("head_to_head", if mine then mine.starlights elseif meRow then 0 else nil),
				w.SizedBox({height = 14}),
				w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = rows}),
				w.SizedBox({height = 6}),
				text("Back to the lobby in " .. view.nextIn, style(12, FAINT, ui.FontWeight.w700), ui.TextAlign.center),
			}}), p.EdgeInsets.fromLTRB(20, 18, 20, 16), true),
		})})}),
	}})
end

local Board = {}

function Board.build(view: View): w.Widget
	local column = w.LayoutBuilder({builder = function(_context: w.BuildContext, constraints: r.BoxConstraints): w.Widget
		local width = math.min(MAX_WIDTH, constraints.maxWidth) - 24
		-- Everything but the two boards is about this tall; the canvas takes what
		-- is left, the reference 42% of it.
		local fixed = 56 + 10 + 22 + 10 + 24 + 10 + 8 + 10 + STRIP
		local canvasSide = math.max(150, math.min(width, (constraints.maxHeight - fixed) / 1.42))
		local referenceSide = canvasSide * 0.42
		local referenceArea: w.Widget
		if view.phase == "prep" or view.phase == "waiting" or not view.reference then
			referenceArea = instructions(view, referenceSide + 22)
		else
			referenceArea = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
				caption("Reference"),
				w.SizedBox({height = 6}),
				panel(board(view.pool, view.reference :: {number}, referenceSide, 4, nil, "ref"), p.EdgeInsets.all(6)),
			}})
		end
		local enabled = view.onTap ~= nil
		local canvas = panel(board(view.pool, view.cells, canvasSide - 20, 8, view.onTap, "cell"), p.EdgeInsets.all(10))
		return w.Align({alignment = p.Alignment.topCenter, child = w.SizedBox({width = width, child = w.Column({
			crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
				status(view),
				w.SizedBox({height = 10}),
				w.Center({child = referenceArea}),
				w.SizedBox({height = 10}),
				w.Row({children = {
					w.Expanded({child = caption(if view.spectating then "Canvas" else "Your canvas")}),
					text(view.matched .. " / 9 matched", style(11, FAINT, ui.FontWeight.w800, 0.6)),
				}}),
				w.SizedBox({height = 6}),
				w.Center({child = w.Opacity({opacity = if enabled or view.done or view.phase == "over" then 1 else 0.55, child = canvas})}),
				w.SizedBox({height = 8}),
				w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 8}), child = m.LinearProgressIndicator({
					value = view.matched / Rules.CELLS, minHeight = 5, backgroundColor = TILE_EMPTY, color = LILAC,
					borderRadius = p.BorderRadius.circular(3)})}),
				w.Spacer({}),
				strip(view),
			}})})})
	end})
	local layers: {w.Widget} = {
		w.SafeArea({child = w.Padding({padding = p.EdgeInsets.fromLTRB(0, HUD_TOP, 0, 8), child = column})}),
	}
	local covered = podium(view)
	if covered then table.insert(layers, covered) end
	-- Every touch lands here: nobody walks off while matching.
	return w.Listener({behavior = r.HitTestBehavior.opaque, child = w.Stack({fit = w.StackFit.expand, children = layers})})
end

return table.freeze(Board)
