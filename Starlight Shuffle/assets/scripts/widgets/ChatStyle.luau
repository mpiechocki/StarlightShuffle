--!strict
--@client
-- The chat's panels' look (the chat rules, a message's menu), ported from Sky
-- Lounge's HudStyle: a solid dark surface that stays readable over the scene,
-- raised rows on it, lavender accents and pink for problems, and the small
-- pieces the panels are built from.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local m = require("@flutter/material")
local animation = require("@flutter/animation")
local ui = require("@dart/ui")
local core = require("@dart/core")
local mdi = require("@icons/mdi")
local Pressable = require("./Pressable")

local function color(value: number): ui.Color return ui.Color({value = value}) end

local Style = {}
Style.color = color
Style.WHITE = color(0xffffffff)
Style.SURFACE = color(0xf81c1a24) -- the panel: nearly opaque, so the scene never shows through text
Style.PILL = color(0xeb1c1a24) -- the closed button
Style.RAISED = color(0xff2a2736) -- rows and cards on the panel
Style.PRESSED = color(0xff363245)
Style.LINE = color(0x1fffffff)
Style.HINT = color(0xb3ffffff)
Style.FAINT = color(0x80ffffff)
Style.ACCENT = color(0xffb0a8ea)
Style.ACCENT_FILL = color(0x33b0a8ea)
Style.ERROR = color(0xffff7aa8)
Style.ERROR_FILL = color(0x29ff7aa8)
Style.INK = color(0xff141416) -- on accent
Style.SCRIM = color(0x590b0a12) -- dims the scene behind the open panel
Style.SHADE = color(0xd90b0a12) -- covers the game when the connection is lost
Style.SHADOW = color(0x73000000)
Style.CLEAR = color(0x00000000)

function Style.style(size: number, colour: ui.Color, weight: ui.FontWeight?, spacing: number?): p.TextStyle
	return p.TextStyle({fontSize = size, color = colour, fontWeight = weight, letterSpacing = spacing})
end

-- One line (or [lines]) of text, cut with an ellipsis.
function Style.text(data: string, textStyle: p.TextStyle, lines: number?, align: ui.TextAlign?): w.Widget
	return w.Text({data = data, style = textStyle, maxLines = lines or 1, overflow = w.TextOverflow.ellipsis, textAlign = align})
end

function Style.spinner(size: number): w.Widget
	return w.SizedBox({width = size, height = size, child = m.CircularProgressIndicator({strokeWidth = 2, color = Style.ACCENT})})
end

function Style.key(value: string?): w.Key?
	return if value then w.ValueKey({value = value}) else nil
end

-- `danger` is for what cannot be taken back, such as a report.
export type ButtonKind = "filled" | "tonal" | "quiet" | "danger"
export type ButtonProps = {
	label: string, onTap: (() -> ())?, kind: ButtonKind?, key: string?,
	icon: mdi.IconRef?, height: number?,
}

-- A rounded button; a missing onTap shows it disabled.
function Style.button(props: ButtonProps): w.Widget
	local kind = props.kind or "tonal"
	local height = props.height or 36
	local ink = if kind == "filled" then Style.INK elseif kind == "tonal" then Style.ACCENT
		elseif kind == "danger" then Style.ERROR else Style.WHITE
	local children: {w.Widget} = {}
	if props.icon then
		table.insert(children, w.Icon({icon = props.icon, size = 18, color = ink}))
		table.insert(children, w.SizedBox({width = 6}))
	end
	table.insert(children, w.Flexible({child = Style.text(props.label, Style.style(if height >= 44 then 15 else 13, ink, ui.FontWeight.w700))}))
	local enabled = props.onTap ~= nil
	return Pressable({key = Style.key(props.key), onTap = props.onTap, label = props.label,
		child = w.Opacity({opacity = if enabled then 1 else 0.4, child = w.Container({height = height,
			padding = p.EdgeInsets.symmetric({horizontal = 14}), alignment = p.Alignment.center,
			decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(height / 2),
				color = if kind == "filled" then Style.ACCENT elseif kind == "tonal" then Style.ACCENT_FILL
					elseif kind == "danger" then Style.ERROR_FILL else Style.RAISED}),
			child = w.Row({mainAxisSize = w.MainAxisSize.min, mainAxisAlignment = w.MainAxisAlignment.center, children = children})})})})
end

-- A 40-point round icon button.
function Style.iconButton(icon: mdi.IconRef, label: string, onTap: (() -> ())?, key: string?): w.Widget
	return Pressable({key = Style.key(key), onTap = onTap, label = label, depth = 0.12,
		child = w.SizedBox({width = 40, height = 40, child = w.Center({child = w.Opacity({opacity = if onTap then 1 else 0.4,
			child = w.Icon({icon = icon, size = 20, color = Style.HINT})})})})})
end

-- A section label, with something at its end that gives way to it when
-- space runs short (large text, narrow screens).
function Style.heading(label: string, trailing: w.Widget?): w.Widget
	local title = Style.text(label, Style.style(13, Style.WHITE, ui.FontWeight.w800))
	local children: {w.Widget} = if trailing
		then {title, w.SizedBox({width = 12}), w.Expanded({child = w.Align({alignment = p.Alignment.centerRight, child = trailing})})}
		else {w.Expanded({child = title})}
	return w.SizedBox({height = 34, child = w.Row({children = children})})
end

local SWAP = core.Duration({milliseconds = 240})
local RISEN = ui.Offset({dx = 0, dy = 0})
local LOW = ui.Offset({dx = 0, dy = 0.03}) -- of its own height, where an arriving screen comes up from

-- An arriving screen fades in as it rises a little into place; a leaving one
-- fades out as it sinks back.
local function rise(child: w.Widget, shown: animation.Animation): w.Widget
	return w.FadeTransition({opacity = shown, child = w.SlideTransition({animation = shown, begin = LOW, ["end"] = RISEN,
		child = child})})
end

-- Both screens pinned to the top while they cross. Only the arriving one
-- takes up room, so a card that eases its size goes straight to the new
-- screen's instead of holding the larger of the two until the old one is gone.
local function pinned(current: w.Widget?, previous: {read w.Widget}): w.Widget
	local children: {w.Widget} = {}
	-- A leaving screen is held to the arriving one's box, clipped as it fades.
	for _, child in previous do table.insert(children, w.Positioned.fill({child = child})) end
	if current then table.insert(children, current) end
	return w.Stack({alignment = p.Alignment.topCenter, children = children})
end

-- Both screens centred while they cross (cards of their own, each its own size).
local function centred(current: w.Widget?, previous: {read w.Widget}): w.Widget
	local children: {w.Widget} = {}
	for _, child in previous do table.insert(children, child) end
	if current then table.insert(children, current) end
	return w.Stack({alignment = p.Alignment.center, children = children})
end

-- One screen giving way to another: [child]'s key says which it is. With
-- [resize], the space it takes eases to the new screen's size too; with
-- [centre], screens of different heights cross about their middles.
function Style.swap(child: w.Widget, resize: boolean?, centre: boolean?): w.Widget
	local switcher = w.AnimatedSwitcher({duration = SWAP, switchInCurve = animation.Curves.easeOutCubic,
		switchOutCurve = animation.Curves.easeInCubic, transitionBuilder = rise,
		layoutBuilder = if centre then centred else pinned, child = child})
	if not resize then return switcher end
	return w.AnimatedSize({duration = SWAP, curve = animation.Curves.easeOutCubic, alignment = p.Alignment.topCenter,
		child = switcher})
end

-- A raised, rounded card.
function Style.card(child: w.Widget, padding: p.EdgeInsets?, key: string?): w.Widget
	return w.Container({key = Style.key(key), padding = padding or p.EdgeInsets.all(12),
		decoration = p.BoxDecoration({color = Style.RAISED, borderRadius = p.BorderRadius.circular(14)}), child = child})
end

return table.freeze(Style)
