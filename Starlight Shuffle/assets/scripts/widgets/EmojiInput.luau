--!strict
--@client
-- The chat bar's text with its emoji drawn in place. Each emoji is one
-- private-use character of the field's text (client/Emojis), so the cursor,
-- selection and deletion treat it as a whole; a `:name:` code typed to its
-- closing colon becomes one, and sending writes the codes back. Offsets are
-- UTF-16 code units, as Dart's are.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local s = require("@flutter/services")
local ui = require("@dart/ui")
local es = require("@es/ui")
local Emojis = require("../client/Emojis")
local EmojiCodes = require("../shared/EmojiCodes")
local EmojiText = require("./EmojiText")

local EmojiInput = {}

-- [text]'s length in UTF-16 code units.
local function units(text: string): number
	local count = 0
	for _, code in utf8.codes(text) do count += if code >= 0x10000 then 2 else 1 end
	return count
end

-- A controller that draws [catalog]'s emoji (the session's by default) at
-- [fontSize], again once the catalog loads; the second result unsubscribes.
function EmojiInput.controller(fontSize: number, catalog: Emojis.Catalog?): (w.InlineWidgetTextEditingController, () -> ())
	local emojis = catalog or Emojis
	local size = EmojiText.size(fontSize)
	local controller = w.InlineWidgetTextEditingController({})
	local function draw()
		for _, emoji in emojis.all() do
			controller:setCharacterWidget(emoji.char, es.WebImage({url = emoji.url, width = size, height = size,
				fit = p.BoxFit.contain, showLoading = false}))
		end
	end
	draw()
	return controller, if catalog then function() end else Emojis.subscribe(draw)
end

-- Puts [emoji] over the selection, at the cursor, or at the end without one,
-- and leaves the cursor after it.
function EmojiInput.insert(controller: w.TextEditingController, emoji: Emojis.Emoji)
	local value = controller.value
	local selection = value.selection
	local start, finish
	if selection.baseOffset >= 0 and selection.extentOffset >= 0 then
		start = math.min(selection.baseOffset, selection.extentOffset)
		finish = math.max(selection.baseOffset, selection.extentOffset)
	else
		start = units(value.text); finish = start
	end
	controller.value = value:replaced(ui.TextRange({start = start, ["end"] = finish}), utf8.char(emoji.char))
		:copyWith({selection = s.TextSelection.collapsed({offset = start + 1}), composing = ui.TextRange.empty})
end

-- [value] with each finished code of a known emoji made its character, the
-- selection and composing range moved to match; nil when there is none. A
-- code the keyboard is still composing stays as typed.
function EmojiInput.convert(value: s.TextEditingValue, catalog: Emojis.Catalog?): s.TextEditingValue?
	local emojis = catalog or Emojis
	local text = value.text
	if not string.find(text, ":[%w_]+:") then return nil end
	local composing = value.composing
	local pieces: {string} = {}
	-- The replaced codes' UTF-16 ranges, in order.
	local replaced: {{start: number, finish: number}} = {}
	local from, offset = 1, 0 -- a byte position and its UTF-16 offset
	while true do
		local first, last, name = string.find(text, ":([%w_]+):", from)
		if not first or not last then break end
		local start = offset + units(string.sub(text, from, first - 1))
		local finish = start + (last - first + 1) -- a code is ASCII
		local emoji = if name then emojis.find(name) else nil
		local composed = composing.start >= 0 and composing.start < finish and composing["end"] > start
		if emoji and not composed then
			table.insert(pieces, string.sub(text, from, first - 1))
			table.insert(pieces, utf8.char(emoji.char))
			table.insert(replaced, {start = start, finish = finish})
			from, offset = last + 1, finish
		else
			-- Its closing colon may open the next code, as in `:x:heart:`.
			table.insert(pieces, string.sub(text, from, last - 1))
			from, offset = last, finish - 1
		end
	end
	if #replaced == 0 then return nil end
	table.insert(pieces, string.sub(text, from))
	local function moved(position: number): number
		if position < 0 then return position end
		local shift = 0
		for _, range in replaced do
			if position >= range.finish then
				shift += range.finish - range.start - 1
			elseif position > range.start then
				return range.start + 1 - shift -- inside a code: after its emoji
			else
				break
			end
		end
		return position - shift
	end
	local selection = value.selection
	return s.TextEditingValue({text = table.concat(pieces),
		selection = s.TextSelection({baseOffset = moved(selection.baseOffset), extentOffset = moved(selection.extentOffset)}),
		composing = if composing.start >= 0
			then ui.TextRange({start = moved(composing.start), ["end"] = moved(composing["end"])})
			else ui.TextRange.empty})
end

-- Turns finished codes into emoji as they are typed or pasted.
function EmojiInput.formatter(catalog: Emojis.Catalog?): s.TextInputFormatter
	return s.TextInputFormatter.withFunction(function(_: s.TextEditingValue, value: s.TextEditingValue): s.TextEditingValue
		return EmojiInput.convert(value, catalog) or value
	end)
end

-- [text] with its emoji written as codes again, as messages carry them.
function EmojiInput.encode(text: string, catalog: Emojis.Catalog?): string
	-- Private-use characters (U+E000 to U+F8FF) start with these bytes.
	if not string.find(text, "[\238\239]") then return text end
	local emojis = catalog or Emojis
	local out: {string} = {}
	for _, code in utf8.codes(text) do
		local emoji = emojis.byChar(code)
		table.insert(out, if emoji then EmojiCodes.code(emoji.name) else utf8.char(code))
	end
	return table.concat(out)
end

return table.freeze(EmojiInput)
