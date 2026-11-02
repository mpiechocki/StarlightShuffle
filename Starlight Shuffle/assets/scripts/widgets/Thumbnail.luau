--!strict
--@client
-- A player's round avatar thumbnail (their head, as the app's profile
-- pictures show it), or their initial on a colour picked by their player id
-- when they have none or it fails to load.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local Style = require("./ChatStyle")

local BACKDROP = Style.color(0xff3a3550)
-- Placeholder colours, picked by player id.
local TINTS = {
	Style.color(0xff8f84d8), Style.color(0xffd889b8), Style.color(0xff5fae9f),
	Style.color(0xffd39a62), Style.color(0xff6f9fd8),
}

-- The first character of [name], upper-cased when it has a case.
local function initial(name: string): string
	return string.upper(string.match(name, "^[\1-\127\194-\244][\128-\191]*") or "?")
end

local function placeholder(player: number, name: string, size: number): w.Widget
	return w.Container({width = size, height = size, alignment = p.Alignment.center,
		decoration = p.BoxDecoration({color = TINTS[math.floor(player % #TINTS) + 1], shape = p.BoxShape.circle}),
		child = w.Text({data = initial(name), style = Style.style(math.round(size * 0.4), Style.WHITE, ui.FontWeight.w800)})})
end

-- [player]'s thumbnail from [url], [size] across.
return function(player: number, name: string, url: string?, size: number): w.Widget
	if not url then return placeholder(player, name, size) end
	return w.Container({width = size, height = size,
		decoration = p.BoxDecoration({color = BACKDROP, shape = p.BoxShape.circle}),
		child = w.ClipOval({child = w.Image.network({src = url, width = size, height = size, fit = p.BoxFit.cover,
			filterQuality = ui.FilterQuality.none, gaplessPlayback = true, excludeFromSemantics = true,
			errorBuilder = function(_: w.BuildContext, _: unknown, _: unknown): w.Widget
				return placeholder(player, name, size)
			end})})})
end
