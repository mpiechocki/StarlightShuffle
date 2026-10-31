--!strict
--@client
-- A player's avatar as UI: their outfit's full-body render (the platform's
-- trimmed composite image, aspect kept) or a portrait cropped to the head from
-- it. The same outfit gives the same picture on every client. A neutral
-- silhouette shows if the image fails to load.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local es = require("@es/ui")
local Appearance = require("../client/Appearance")

local AvatarImage = {}

local function fallback(width: number, height: number): w.Widget
	return w.SizedBox({width = width, height = height, child = w.Align({alignment = p.Alignment.bottomCenter,
		child = w.Container({width = width * 0.45, height = height * 0.8, decoration = p.BoxDecoration({
			color = ui.Color({value = 0x55ffffff}), borderRadius = p.BorderRadius.vertical({top = ui.Radius.circular(width * 0.25)})})})})})
end

-- The full body, [height] tall, standing on the bottom of a [width] box.
function AvatarImage.body(outfit: {number}?, width: number, height: number): w.Widget
	return es.WebImage({url = Appearance.url(outfit or Appearance.STARTER), width = width, height = height,
		fit = p.BoxFit.contain, alignment = p.Alignment.bottomCenter, showLoading = false,
		errorWidget = function(_: w.BuildContext, _url: string, _error: unknown): w.Widget return fallback(width, height) end})
end

-- The head and hair, [size] square: the top of the render, its middle 70%.
function AvatarImage.head(outfit: {number}?, size: number): w.Widget
	local wide = size * 1.42
	return w.ClipRect({child = w.SizedBox({width = size, height = size, child = w.OverflowBox({
		alignment = p.Alignment.topCenter, minWidth = wide, maxWidth = wide, minHeight = 0, maxHeight = size * 4,
		child = es.WebImage({url = Appearance.url(outfit or Appearance.STARTER), width = wide, fit = p.BoxFit.fitWidth,
			alignment = p.Alignment.topCenter, showLoading = false,
			errorWidget = function(_: w.BuildContext, _url: string, _error: unknown): w.Widget return fallback(size, size) end}),
	})})})
end

return table.freeze(AvatarImage)
