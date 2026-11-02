--!strict
-- Chat writes emoji as `:name:` shortcodes, as the app does: letters, digits and
-- underscores between colons. A code that names no emoji stays as typed.
local EmojiCodes = {}

export type Part = { read text: string?, read emoji: string? }

-- Splits [text] into plain runs and the emoji names [known] accepts, in order.
function EmojiCodes.parts(text: string, known: (string) -> boolean): {Part}
	local parts: {Part} = {}
	local plain, from = 1, 1
	while true do
		local first, last, name = string.find(text, ":([%w_]+):", from)
		if not first or not last then break end
		if name and known(name) then
			if first > plain then table.insert(parts, { text = string.sub(text, plain, first - 1) }) end
			table.insert(parts, { emoji = name })
			plain, from = last + 1, last + 1
		else
			-- Its closing colon may open the next code, as in `:x:heart:`.
			from = last
		end
	end
	if plain <= #text then table.insert(parts, { text = string.sub(text, plain) }) end
	return parts
end

-- The shortcode for an emoji name.
function EmojiCodes.code(name: string): string return ":" .. name .. ":" end

return table.freeze(EmojiCodes)
