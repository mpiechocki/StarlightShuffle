--!strict
--@client
-- A player's role icons and name colours (client/Roles), for labels and chat.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local es = require("@es/ui")
local Roles = require("../client/Roles")

local RoleIcons = {}

-- [roles]' icons in a row, each [size] pixels square with [gap] before it;
-- nil when none of them has one.
function RoleIcons.row(roles: {string}?, size: number, gap: number): w.Widget?
	local urls = Roles.icons(roles)
	if #urls == 0 then return nil end
	local children: {w.Widget} = {}
	for _, url in urls do
		table.insert(children, w.Padding({padding = p.EdgeInsets.only({left = gap}), child = es.WebImage({url = url,
			width = size, height = size, fit = p.BoxFit.contain, showLoading = false})}))
	end
	return w.Row({mainAxisSize = w.MainAxisSize.min, children = children})
end

-- [rgb] (0xRRGGBB) taken [t] (0..1) of the way to white.
function RoleIcons.mix(rgb: number, t: number): number
	local out = 0
	for shift = 0, 16, 8 do
		local channel = bit32.band(bit32.rshift(rgb, shift), 0xff)
		out += bit32.lshift(math.round(channel + (255 - channel) * t), shift)
	end
	return out
end

-- [rgb] lifted toward white as far as it needs to read on dark glass: the
-- platform's darker role colours (deep blues and purples) are made for light
-- pages.
function RoleIcons.onDark(rgb: number): number
	local r, g, b = bit32.rshift(rgb, 16) / 255, bit32.band(bit32.rshift(rgb, 8), 0xff) / 255, bit32.band(rgb, 0xff) / 255
	local luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
	return if luma >= 0.5 then rgb else RoleIcons.mix(rgb, (0.5 - luma) / (1 - luma))
end

return table.freeze(RoleIcons)
