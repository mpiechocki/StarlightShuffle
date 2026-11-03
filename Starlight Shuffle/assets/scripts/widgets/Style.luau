--!strict
--@client
-- The HUD's look: dark, nearly opaque surfaces that stay readable over any
-- scene, starlight gold for Starlights and the big actions, and the small
-- pieces the HUD is built from.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local fonts = require("@fonts/app")
local material = require("@icons/material")

local function color(value: number): ui.Color return ui.Color({value = value}) end

local Style = {}
Style.color = color
Style.WHITE = color(0xffffffff)
Style.SURFACE = color(0xf2181430)
Style.RAISED = color(0xff26214a)
Style.MINE = color(0xff3a3170)
Style.LINE = color(0x24ffffff)
Style.HINT = color(0xb8ffffff)
Style.FAINT = color(0x80ffffff)
Style.GOLD = color(0xffffc94a)
Style.GOLD_FILL = color(0x33ffc94a)
Style.SKY = color(0xff6fd3ff)
Style.ERROR = color(0xffff7aa8)
Style.INK = color(0xff1b1636) -- on gold
Style.SCRIM = color(0x800b0a1a)
Style.SHADOW = color(0x66000000)

function Style.style(size: number, colour: ui.Color, weight: ui.FontWeight?): p.TextStyle
	return p.TextStyle({fontFamily = fonts.lato, fontSize = size, color = colour, fontWeight = weight})
end

-- One line (or [lines]) of text, cut with an ellipsis.
function Style.text(data: string, textStyle: p.TextStyle, lines: number?, align: ui.TextAlign?): w.Widget
	return w.Text({data = data, style = textStyle, maxLines = lines or 1, overflow = w.TextOverflow.ellipsis, textAlign = align})
end

function Style.card(child: w.Widget, padding: p.EdgeInsets?, radius: number?): w.Widget
	return w.Container({
		padding = padding or p.EdgeInsets.all(16),
		decoration = p.BoxDecoration({color = Style.SURFACE, borderRadius = p.BorderRadius.circular(radius or 18),
			border = p.Border.all({color = Style.LINE, width = 1}),
			boxShadow = {p.BoxShadow({color = Style.SHADOW, blurRadius = 16, offset = ui.Offset({dx = 0, dy = 4})})}}),
		child = child,
	})
end

-- A pill: an icon (an 18 px widget), then a label.
function Style.pill(icon: w.Widget, label: string): w.Widget
	return w.Container({
		padding = p.EdgeInsets.symmetric({horizontal = 14, vertical = 8}),
		decoration = p.BoxDecoration({color = Style.SURFACE, borderRadius = p.BorderRadius.circular(999),
			border = p.Border.all({color = Style.LINE, width = 1})}),
		child = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
			icon,
			w.SizedBox({width = 6}),
			Style.text(label, Style.style(15, Style.WHITE, ui.FontWeight.w700)),
		}}),
	})
end

-- A round button for the HUD's head: [filled] in gold, else on a surface.
function Style.roundButton(icon: material.IconRef, onTap: () -> (), filled: boolean, key: string): w.Widget
	return w.GestureDetector({key = w.ValueKey({value = key}), onTap = onTap, child = w.Container({
		width = 52, height = 52,
		decoration = p.BoxDecoration({color = if filled then Style.GOLD else Style.SURFACE, shape = p.BoxShape.circle,
			border = p.Border.all({color = if filled then Style.GOLD else Style.LINE, width = 1.5}),
			boxShadow = {p.BoxShadow({color = Style.SHADOW, blurRadius = 10, offset = ui.Offset({dx = 0, dy = 3})})}}),
		child = w.Icon({icon = icon, size = 28, color = if filled then Style.INK else Style.WHITE}),
	})})
end

-- A wide button with a label.
function Style.button(label: string, onTap: (() -> ())?, key: string): w.Widget
	return w.GestureDetector({key = w.ValueKey({value = key}), onTap = onTap, child = w.Container({
		padding = p.EdgeInsets.symmetric({horizontal = 22, vertical = 12}),
		decoration = p.BoxDecoration({color = if onTap then Style.GOLD else Style.RAISED, borderRadius = p.BorderRadius.circular(999)}),
		child = Style.text(label, Style.style(15, if onTap then Style.INK else Style.FAINT, ui.FontWeight.w800), 1, ui.TextAlign.center),
	})})
end

-- "1:05", or "9" under a minute when [short].
function Style.clock(seconds: number, short: boolean?): string
	local whole = math.max(0, math.ceil(seconds))
	if short and whole < 60 then return tostring(whole) end
	return string.format("%d:%02d", whole // 60, whole % 60)
end

-- 1234567 as "1,234,567".
function Style.count(n: number): string
	local text = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

return table.freeze(Style)
