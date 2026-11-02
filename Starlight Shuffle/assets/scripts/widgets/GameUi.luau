--!strict
--@client
-- The mini-games' shared chrome, so every game reads as one experience:
-- theme tokens (translucent plum HUD, velvet-purple results, muted lilac
-- borders), the HUD panel, the pre-round instruction card and countdown, and
-- the results card, rows and podium. Game-specific HUD content goes inside
-- these pieces.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local fonts = require("@fonts/app")
local AvatarImage = require("./AvatarImage")

local function color(v: number): ui.Color return ui.Color({value = v}) end

local GameUi = {}
GameUi.color = color
GameUi.HUD = color(0x9c473655) -- translucent plum game chrome
GameUi.HUD_EDGE = color(0x55ffffff)
GameUi.PANEL = color(0xf733243f) -- velvet purple
GameUi.ROW = color(0xff493257)
GameUi.ROW_MINE = color(0xff5d4170)
GameUi.BORDER = color(0xffa589b4)
GameUi.TEXT = color(0xfff5eafa)
GameUi.MUTED = color(0xffd7bedf)
GameUi.SOFT = color(0xffdfd0e9)
GameUi.ACTION = color(0xff6d4c83)
GameUi.CARD = color(0xedfff7ff) -- the pale lavender instruction card
GameUi.CARD_TEXT = color(0xff69527e)
GameUi.CARD_MUTED = color(0xffa085b3)
GameUi.RADIUS = 17
GameUi.MEDALS = table.freeze({ 0xffe2b65a, 0xffc9cbd8, 0xffc98b5c })

function GameUi.style(size: number, colour: ui.Color, weight: ui.FontWeight?, spacing: number?, italic: boolean?): p.TextStyle
	return p.TextStyle({fontFamily = fonts.lato, fontSize = size, color = colour, fontWeight = weight, letterSpacing = spacing,
		fontStyle = if italic then ui.FontStyle.italic else nil})
end
local style = GameUi.style

-- A small translucent plum HUD panel.
function GameUi.hud(child: w.Widget, padding: p.EdgeInsets?): w.Widget
	return w.Container({
		padding = padding or p.EdgeInsets.symmetric({horizontal = 12, vertical = 8}),
		decoration = p.BoxDecoration({color = GameUi.HUD, borderRadius = p.BorderRadius.circular(15),
			border = p.Border.all({color = GameUi.HUD_EDGE, width = 1})}),
		child = child,
	})
end

-- A small uppercase overline.
function GameUi.overline(text: string, colour: ui.Color?): w.Widget
	return w.Text({data = string.upper(text), style = style(9, colour or GameUi.MUTED, ui.FontWeight.w800, 1.6)})
end

-- The pre-round card: an instruction and whatever the game adds (its legend).
function GameUi.instructionCard(children: {w.Widget}): w.Widget
	return w.Center({child = w.Padding({padding = p.EdgeInsets.all(24), child = w.ConstrainedBox({
		constraints = r.BoxConstraints({maxWidth = 330}), child = w.Container({
			padding = p.EdgeInsets.fromLTRB(22, 20, 22, 18),
			decoration = p.BoxDecoration({color = GameUi.CARD, borderRadius = p.BorderRadius.circular(22),
				border = p.Border.all({color = color(0xffffffff), width = 1}),
				boxShadow = {p.BoxShadow({color = color(0x2671548e), blurRadius = 30, offset = ui.Offset({dx = 0, dy = 10})})}}),
			child = w.Column({mainAxisSize = w.MainAxisSize.min, children = children}),
		})})})})
end

-- One line of the instruction card.
function GameUi.instruction(text: string, strong: boolean?): w.Widget
	return w.Text({data = text, textAlign = ui.TextAlign.center,
		style = style(if strong then 17 else 13, if strong then GameUi.CARD_TEXT else GameUi.CARD_MUTED,
			if strong then ui.FontWeight.w800 else ui.FontWeight.w600)})
end

-- The large final countdown number.
function GameUi.countdown(n: number): w.Widget
	return w.IgnorePointer({child = w.Center({child = w.Text({data = tostring(n),
		style = p.TextStyle({fontFamily = fonts.lato, fontSize = 84, fontWeight = ui.FontWeight.w900, color = color(0xfffff4df),
			shadows = {ui.Shadow({color = color(0x66a588be), offset = ui.Offset({dx = 3, dy = 4}), blurRadius = 0})}})})})})
end

-- A podium place's medal: gold, silver, bronze; a plain disc after that.
function GameUi.medal(place: number, size: number?): w.Widget
	local d = size or 26
	return w.Container({width = d, height = d, decoration = p.BoxDecoration({color = color(GameUi.MEDALS[place] or 0xff7a6189),
		shape = p.BoxShape.circle, border = p.Border.all({color = color(0x66ffffff), width = 1.5})}),
		child = w.Center({child = w.Text({data = tostring(place),
			style = style(d * 0.46, if GameUi.MEDALS[place] then color(0xff3a2a24) else GameUi.TEXT, ui.FontWeight.w900)})})})
end

-- A results row: a rounded plum row, highlighted when it is yours.
function GameUi.row(child: w.Widget, mine: boolean, key: string?): w.Widget
	return w.Container({key = if key then w.ValueKey({value = key}) else nil,
		margin = p.EdgeInsets.only({bottom = 8}), padding = p.EdgeInsets.symmetric({horizontal = 12, vertical = 9}),
		decoration = p.BoxDecoration({color = if mine then GameUi.ROW_MINE else GameUi.ROW, borderRadius = p.BorderRadius.circular(12),
			border = if mine then p.Border.all({color = GameUi.BORDER, width = 1}) else nil}),
		child = child})
end

-- A small rounded portrait frame around [child] (a head).
function GameUi.portrait(child: w.Widget): w.Widget
	return w.ClipRRect({borderRadius = p.BorderRadius.circular(9), child = w.Container({color = color(0x33ffffff), child = child})})
end

-- The results card over a dim scrim: THAT'S A WRAP above [children], which
-- scroll inside the card when they do not fit.
function GameUi.wrap(children: {w.Widget}): w.Widget
	local content: {w.Widget} = {
		w.Text({data = "THAT'S A WRAP", style = style(10, GameUi.MUTED, ui.FontWeight.w800, 2)}),
		w.SizedBox({height = 12}),
	}
	for _, child in children do table.insert(content, child) end
	return w.Stack({fit = w.StackFit.expand, children = {
		w.Container({color = color(0x80140c22)}),
		w.SafeArea({child = w.Center({child = w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 15, vertical = 12}), child = w.ConstrainedBox({
			constraints = r.BoxConstraints({maxWidth = 400}), child = w.Container({
				decoration = p.BoxDecoration({color = GameUi.PANEL, borderRadius = p.BorderRadius.circular(GameUi.RADIUS),
					border = p.Border.all({color = GameUi.BORDER, width = 1})}),
				child = w.SingleChildScrollView({padding = p.EdgeInsets.fromLTRB(18, 26, 18, 18),
					child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = content})}),
			})})})})}),
	}})
end

-- `metric` replaces the points text (Star Pass shows passes).
export type PodiumRow = { place: number, name: string, outfit: {number}?, points: number, mine: boolean, metric: string? }
export type Podium = { heading: string, summary: string, rows: {PodiumRow}, footer: string }

-- The results: THAT'S A WRAP, an italic heading, one summary line and up to
-- three podium rows (medal, portrait, name or "you", points).
function GameUi.podium(props: Podium): w.Widget
	local rows: {w.Widget} = {}
	for _, row in props.rows do
		if row.place > 3 then break end
		table.insert(rows, GameUi.row(w.Row({children = {
			GameUi.medal(row.place),
			w.SizedBox({width = 10}),
			GameUi.portrait(AvatarImage.head(row.outfit, 36)),
			w.SizedBox({width = 10}),
			w.Expanded({child = w.Text({data = if row.mine then "you" else row.name, maxLines = 1, overflow = w.TextOverflow.ellipsis,
				style = style(15, GameUi.TEXT, ui.FontWeight.w800)})}),
			w.Text({data = row.metric or (row.points .. (if math.abs(row.points) == 1 then " pt" else " pts")),
				style = style(14, GameUi.SOFT, ui.FontWeight.w800)}),
		}}), row.mine, "place" .. row.place))
	end
	return GameUi.wrap({
		w.Text({data = props.heading, style = style(28, GameUi.TEXT, ui.FontWeight.w700, -0.5, true)}),
		w.SizedBox({height = 10}),
		w.Text({data = props.summary, style = style(13, GameUi.SOFT)}),
		w.SizedBox({height = 18}),
		w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = rows}),
		w.SizedBox({height = 6}),
		w.Text({data = props.footer, textAlign = ui.TextAlign.center, style = style(12, GameUi.MUTED, ui.FontWeight.w700)}),
	})
end

return table.freeze(GameUi)
