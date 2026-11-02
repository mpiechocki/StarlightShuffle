--!strict
--@client
-- Chat text with the app's custom emoji drawn inline, a little taller than the
-- letters. Text built before the catalog loads shows its codes as typed, so its
-- owner rebuilds on Emojis.subscribe.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local es = require("@es/ui")
local Emojis = require("../client/Emojis")
local EmojiCodes = require("../shared/EmojiCodes")

local EmojiText = {}

-- How big an emoji is in text of [fontSize].
function EmojiText.size(fontSize: number): number return math.round(fontSize * 1.4) end

-- [text] as spans, each known emoji an image [size] pixels square, and how
-- many emoji there are. [urls] stands in for the session's catalog.
function EmojiText.spans(text: string, size: number, urls: {read [string]: string}?): ({p.InlineSpan}, number)
	local function url(name: string): string?
		return if urls then urls[name] else Emojis.url(name)
	end
	local function known(name: string): boolean return url(name) ~= nil end
	local spans: {p.InlineSpan}, count = {}, 0
	for _, part in EmojiCodes.parts(text, known) do
		local name = part.emoji
		local image = if name then url(name) else nil
		if name and image then
			count += 1
			table.insert(spans, w.WidgetSpan({alignment = ui.PlaceholderAlignment.middle, child = w.Semantics({
				label = EmojiCodes.code(name), child = es.WebImage({url = image, width = size, height = size,
					fit = p.BoxFit.contain, showLoading = false})})}))
		elseif part.text then
			table.insert(spans, p.TextSpan({text = part.text}))
		end
	end
	return spans, count
end

-- The names of the emoji [text] is made of, when it is nothing but up to
-- [most] of them (spaces aside): such a message shows them big. Nil otherwise.
function EmojiText.only(text: string, most: number, urls: {read [string]: string}?): {string}?
	local function known(name: string): boolean
		return (if urls then urls[name] else Emojis.url(name)) ~= nil
	end
	local names: {string} = {}
	for _, part in EmojiCodes.parts(text, known) do
		if part.emoji then
			table.insert(names, part.emoji)
			if #names > most then return nil end
		elseif part.text and string.find(part.text, "%S") then
			return nil
		end
	end
	return if #names > 0 then names else nil
end

-- The gap between big emoji in a row, for [size].
function EmojiText.gap(size: number): number return math.round(size / 10) end

-- [names] (see only) side by side, each [size] pixels square.
function EmojiText.row(names: {string}, size: number, urls: {read [string]: string}?): w.Widget
	local children: {w.Widget} = {}
	for i, name in names do
		local image = if urls then urls[name] else Emojis.url(name)
		if not image then continue end
		if i > 1 then table.insert(children, w.SizedBox({width = EmojiText.gap(size)})) end
		table.insert(children, w.Semantics({label = EmojiCodes.code(name), child = es.WebImage({url = image,
			width = size, height = size, fit = p.BoxFit.contain, showLoading = false})}))
	end
	return w.Row({mainAxisSize = w.MainAxisSize.min, children = children})
end

-- What a TextPainter laying out [count] emoji of [size] needs to measure them.
function EmojiText.dimensions(count: number, size: number): {p.PlaceholderDimensions}
	return table.create(count, p.PlaceholderDimensions({size = ui.Size({width = size, height = size}),
		alignment = ui.PlaceholderAlignment.middle}))
end

return table.freeze(EmojiText)
