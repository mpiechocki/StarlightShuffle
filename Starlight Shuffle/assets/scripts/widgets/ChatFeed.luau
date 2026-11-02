--!strict
--@client
-- The latest chat lines along the top left of the view (from [top] down, under
-- the HUD's head), with no box
-- behind them. Each is its speaker's head, their name in a pale tint of their
-- role colour (client/Roles), then what they said, with emoji; shaded to read
-- over the lobby. Newest at the bottom. After a while without a new line, the oldest
-- pops off, then the next, until the feed is empty; a new line holds them
-- again. It never takes touches.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local core = require("@dart/core")
local animation = require("@flutter/animation")
local async = require("@dart/async")
local Chat = require("../client/Chat")
local Emojis = require("../client/Emojis")
local Roles = require("../client/Roles")
local ChatLine = require("./ChatLine")
local EmojiText = require("./EmojiText")
local RoleIcons = require("./RoleIcons")

local function color(value: number): ui.Color return ui.Color({value = value}) end
local LINES = 7 -- shown at most
local WIDTH = 340
local MARGIN = 12
local SIZE = 13
local EMOJI = EmojiText.size(SIZE)
local HEAD = 18 -- a speaker's thumbnail
local QUIET = core.Duration({seconds = 8}) -- without a new line, the oldest pops
local GAP = core.Duration({milliseconds = 1200}) -- then the next, this much later
local POP = core.Duration({milliseconds = 400}) -- a line fading, then folding away
-- A hard drop shadow, without blur: the text drawn once more underneath, where
-- a blurred one would be blurred again on every frame the game draws.
local SHADE = {ui.Shadow({color = color(0xd9000000), blurRadius = 0, offset = ui.Offset({dx = 0, dy = 1})})}
local TEXT = p.TextStyle({fontSize = SIZE, height = 1.3, color = color(0xffffffff), fontWeight = ui.FontWeight.w600,
	shadows = SHADE})
-- A name without a role colour: plain, as in the history (widgets/ChatLine).
local NAME = color(0xccffffff)
-- How far a role colour goes toward white: the sky is about as bright as
-- the role colours, which read on the history's dark glass but not over it.
local PALE = 0.55

type Props = { read chat: Chat.Controller, read top: number? }
-- Lines up to `popped` (by key) are gone and `popping` is on its way out;
-- `timer` is the next pop's.
type Fields = { changed: (() -> ())?, emojis: (() -> ())?, roles: (() -> ())?, popped: number, popping: number?,
	timer: async.Timer? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local function line(said: Chat.Line): w.Widget
	local tint = Roles.color(said.roles)
	local name = if tint then color(0xff000000 + RoleIcons.mix(RoleIcons.onDark(tint), PALE)) else NAME
	local spans: {p.InlineSpan} = {p.TextSpan({text = said.name .. ": ", style = p.TextStyle({fontWeight = ui.FontWeight.w800,
		color = name, shadows = SHADE})})}
	local words = EmojiText.spans(said.text, EMOJI)
	table.move(words, 1, #words, #spans + 1, spans)
	return w.Padding({key = w.ValueKey({value = "feed:" .. said.key}), padding = p.EdgeInsets.only({bottom = 3}),
		child = w.Row({crossAxisAlignment = w.CrossAxisAlignment.start, children = {
			ChatLine.head(said, HEAD),
			w.SizedBox({width = 6}),
			w.Flexible({child = w.Text.rich({textSpan = p.TextSpan({style = TEXT, children = spans}), maxLines = 3,
				overflow = w.TextOverflow.ellipsis})}),
		}})})
end

-- 0 to 1 over [from, to] of t, eased at both ends.
local function ease(t: number, from: number, to: number): number
	local s = math.clamp((t - from) / (to - from), 0, 1)
	return s * s * (3 - 2 * s)
end

-- [said] fading and shrinking a little, then folding its height away so the
-- lines below it rise. Unclipped: it is gone by the fold, and rises into the
-- margin above rather than being cut off against it.
local function popping(said: Chat.Line): w.Widget
	return w.TweenAnimationBuilder({key = w.ValueKey({value = "feed-pop:" .. said.key}),
		tween = animation.Tween({begin = 0, ["end"] = 1}), duration = POP,
		builder = function(_: w.BuildContext, t: number, child: w.Widget?): w.Widget
			local shown = 1 - ease(t, 0, 0.6)
			return w.Align({alignment = p.Alignment.bottomLeft, heightFactor = 1 - ease(t, 0.4, 1),
				child = w.Opacity({opacity = shown, child = w.Transform.scale({scale = 0.92 + 0.08 * shown,
					alignment = p.Alignment.centerLeft, child = child})})})
		end,
		child = line(said)})
end

local function after(self: State, wait: core.Duration, fn: () -> ())
	if self.timer then self.timer:cancel() end
	self.timer = async.Timer.new(wait, fn)
end

-- The oldest line still shown.
local function oldest(self: State): Chat.Line?
	local lines = self.widget.chat.lines
	for i = math.max(1, #lines - LINES + 1), #lines do
		if lines[i].key > self.popped then return lines[i] end
	end
	return nil
end

-- Pops the oldest line, then the next one GAP later, until none is left.
local function pop(self: State)
	if not self.mounted then return end
	local first = oldest(self)
	if not first then return end
	self:setState(function() self.popping = first.key end)
	after(self, POP, function()
		if not self.mounted then return end
		self:setState(function() self.popped, self.popping = first.key, nil end)
		after(self, GAP, function() pop(self) end)
	end)
end

return define("ChatFeed", {
	createState = function(): Fields
		return { changed = nil, emojis = nil, roles = nil, popped = 0, popping = nil, timer = nil }
	end,
	initState = function(self: State)
		local redraw = function()
			if self.mounted then self:setState(function() end) end
		end
		-- A new line holds the rest for QUIET more; one on its way out goes.
		local changed = function()
			if not self.mounted then return end
			after(self, QUIET, function() pop(self) end)
			self:setState(function()
				if self.popping then self.popped, self.popping = self.popping :: number, nil end
			end)
		end
		self.changed = changed
		self.widget.chat.onFeedChanged = changed
		-- Lines that came before the emoji or role catalogs draw them once each loads.
		self.emojis = Emojis.subscribe(redraw)
		self.roles = Roles.subscribe(redraw)
	end,
	dispose = function(self: State)
		if self.widget.chat.onFeedChanged == self.changed then self.widget.chat.onFeedChanged = nil end
		if self.timer then self.timer:cancel() end
		if self.emojis then self.emojis() end
		if self.roles then self.roles() end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local lines = self.widget.chat.lines
		local shown: {w.Widget} = {}
		for i = math.max(1, #lines - LINES + 1), #lines do
			local said = lines[i]
			if said.key > self.popped then
				table.insert(shown, if said.key == self.popping then popping(said) else line(said))
			end
		end
		-- Below the safe area, as the HUD's head is.
		return w.IgnorePointer({child = w.Align({alignment = p.Alignment.topLeft, child = w.SafeArea({
			child = w.Padding({padding = p.EdgeInsets.fromLTRB(MARGIN, self.widget.top or MARGIN, MARGIN, MARGIN),
				child = w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = WIDTH}),
					child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.start,
						children = shown})})})})})})
	end,
})
