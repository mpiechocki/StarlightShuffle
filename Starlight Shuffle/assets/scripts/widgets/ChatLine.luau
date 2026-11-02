--!strict
--@client
-- A chat message as the history shows it (widgets/ChatBar): its words, with
-- emoji, and over a group of them the speaker's head and their name in their
-- role colour, with their role icons (client/Roles). The message menu
-- (widgets/MessageMenu) shows the message it is about the same way.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local Chat = require("../client/Chat")
local AvatarImages = require("../client/AvatarImages")
local Roles = require("../client/Roles")
local EmojiText = require("./EmojiText")
local RoleIcons = require("./RoleIcons")
local Thumbnail = require("./Thumbnail")

local function color(value: number): ui.Color return ui.Color({value = value}) end
local STYLE = p.TextStyle({fontSize = 13, height = 1.3, color = color(0xffffffff)})
local EMOJI = EmojiText.size(13)
-- A line of nothing but a few emoji shows them bigger.
local JUMBO = 24
-- Role icons after a name, as big as the app's.
local ROLE = 11
-- A name without a role colour: plain, as in the app, so only roles colour one.
local NAME = color(0xccffffff)
-- Lato's line box has spare room above its letters, so icons centred beside
-- them sit high.
local DROP = ui.Offset({dx = 0, dy = 1})

local ChatLine = {}

-- One message. A few emoji alone show big.
function ChatLine.message(line: Chat.Line): w.Widget
	local big = EmojiText.only(line.text, 3) ~= nil
	return w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 2}), child = w.Text.rich({
		textAlign = ui.TextAlign.start,
		textSpan = p.TextSpan({style = STYLE, children = (EmojiText.spans(line.text, if big then JUMBO else EMOJI))})})})
end

-- A speaker's name in their role colour, with their role icons.
function ChatLine.speaker(line: Chat.Line): w.Widget
	local tint = Roles.color(line.roles)
	local children: {w.Widget} = {w.Flexible({child = w.Text({data = line.name, maxLines = 1, overflow = w.TextOverflow.ellipsis,
		style = p.TextStyle({fontSize = 12, fontWeight = ui.FontWeight.w700,
			color = if tint then color(0xff000000 + RoleIcons.onDark(tint)) else NAME})})})}
	local icons = RoleIcons.row(line.roles, ROLE, 3)
	if icons then table.insert(children, w.Transform.translate({offset = DROP, child = icons})) end
	return w.Padding({padding = p.EdgeInsets.only({left = 2, bottom = 2}),
		child = w.Row({mainAxisSize = w.MainAxisSize.min, children = children})})
end

-- The speaker's head, [size] across.
function ChatLine.head(line: Chat.Line, size: number): w.Widget
	return Thumbnail(line.player, line.name, if line.avatar then AvatarImages.url(line.avatar) else nil, size)
end

return table.freeze(ChatLine)
