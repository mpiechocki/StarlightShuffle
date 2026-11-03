--!strict
--@client
-- The chat composer along the bottom-left of the screen: one glass card, after
-- the runway project's message bar. Its bubble button opens the recent
-- messages (the latest also show along the top left: widgets/ChatFeed); its
-- smiley opens the app's custom emoji instead. Either grows out of the card's
-- top, above the field. The field shows emoji as images (widgets/EmojiInput);
-- messages carry them as `:name:` codes. Until the chat rules are accepted on
-- this device, the field and the smiley show them first (widgets/ChatRules).
-- A [hint] (the lobby's, pointing at the arcade) shows above the card while
-- nothing is open and the keyboard is down. [expanded] starts it with the
-- history open (a mini-game's chat, opened on purpose).
--
-- The history reads like a group chat: messages in a row from one player are
-- one group, under their head and their name (in their role colour, with
-- their role icons: client/Roles), yours like anyone's; a few emoji alone
-- show big (widgets/ChatLine). Tapping someone else's head opens their
-- profile; a long press on their message offers what can be done with it
-- (widgets/MessageMenu), when anything can.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local m = require("@flutter/material")
local s = require("@flutter/services")
local ui = require("@dart/ui")
local core = require("@dart/core")
local animation = require("@flutter/animation")
local mdi = require("@icons/mdi")
local game = require("@moonbase/game")
local Chat = require("../client/Chat")
local Emojis = require("../client/Emojis")
local Roles = require("../client/Roles")
local Roster = require("../client/Roster")
local ChatText = require("../client/ChatText")
local ChatLine = require("./ChatLine")
local EmojiPicker = require("./EmojiPicker")
local EmojiInput = require("./EmojiInput")
local Pressable = require("./Pressable")

local function color(value: number): ui.Color return ui.Color({value = value}) end
local WHITE = color(0xffffffff)
local GLASS = color(0xb8141416)
local GLASS_LINE = color(0x26ffffff)
local HINT = color(0xb3ffffff)
local ACCENT = color(0xffb0a8ea)
local INK = color(0xff141416)
local DIVIDER = color(0x1fffffff)
-- Half the bar's height: closed, the card is a pill, its Send button's circle
-- (6 in) concentric with the end.
local RADIUS = 24
local MARGIN = 12
-- A panel grows out of the card's top as the old one fades.
local GROW = core.Duration({milliseconds = 150})
local FADE = core.Duration({milliseconds = 90})
local LINE_GAP = 2 -- between one player's messages
local HEAD = 28 -- a speaker's thumbnail
-- Seconds of quiet after which the same player's next message starts a new group.
local GROUP_GAP = 120

type Props = { read chat: Chat.Controller, read hint: w.Widget?, read expanded: boolean? }
type Fields = {
	input: w.InlineWidgetTextEditingController, focus: w.FocusNode, formatter: s.TextInputFormatter,
	-- The history or the emoji panel is open above the bar (never both);
	-- `reopen` is whether the history was open when the emoji panel opened,
	-- and so comes back when it closes.
	open: boolean, picking: boolean, reopen: boolean,
	changed: (() -> ())?, emojis: (() -> ())?, roles: (() -> ())?, inputEmojis: () -> (), dismiss: (() -> boolean)?,
	-- Rebuilds as the field gains or loses focus (the hint goes with the keyboard).
	focused: () -> (),
	-- The card as last built, and how far its bottom sits above the view's.
	card: w.BuildContext?, below: number, covered: (() -> number)?,
}
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>


local function toggle(self: State)
	self:setState(function()
		self.open = not self.open
		self.picking, self.reopen = false, false
	end)
end

-- Closes the emoji panel, the history back as it was.
local function closePicker(self: State)
	self.picking, self.open = false, self.reopen
end

-- Sending leaves focus as it was: typed with the keyboard up, the field keeps
-- it for the next message (the bar's taps never take it); picked with the
-- keyboard down, it stays down. The emoji panel has done its job.
-- Sends [text]; true when it went out.
local function submit(self: State, text: string): boolean
	if not self.widget.chat:send(EmojiInput.encode(text)) then return false end
	self.input:clear()
	if self.picking then self:setState(function() closePicker(self) end) end
	return true
end

local function togglePicker(self: State)
	self:setState(function()
		if self.picking then
			closePicker(self)
		else
			self.picking, self.reopen, self.open = true, self.open, false
		end
	end)
end

-- Shows the chat rules, then [next] with the bar built for chatting.
local function afterRules(self: State, next: () -> ())
	self.widget.chat:askRules(function()
		if not self.mounted then return end
		self:setState(function() end)
		next()
	end)
end

-- A pick goes in at the cursor, as typing would.
local function pick(self: State, emoji: Emojis.Emoji)
	EmojiInput.insert(self.input, emoji)
	self.widget.chat:typed(self.input.text)
	s.HapticFeedback.lightImpact()
end

-- Messages in a row from one player, with no long quiet between them. Yours
-- (`mine`) offer no message menu.
type Group = { from: number, mine: boolean, lines: {Chat.Line} }

local function groupsOf(chat: Chat.Controller): {Group}
	local groups: {Group} = {}
	for _, line in chat.lines do
		local group = groups[#groups]
		local previous = if group then group.lines[#group.lines] else nil
		if group and previous and group.from == line.from and line.at - previous.at < GROUP_GAP then
			table.insert(group.lines, line)
		else
			table.insert(groups, {from = line.from, mine = chat:isMine(line.from), lines = {line}})
		end
	end
	return groups
end

local function group(chat: Chat.Controller, entry: Group): w.Widget
	local messages: {w.Widget} = {}
	for i, line in entry.lines do
		if i > 1 then table.insert(messages, w.SizedBox({height = LINE_GAP})) end
		local body = ChatLine.message(line)
		if not entry.mine and chat:reportLink(line) then
			body = w.GestureDetector({behavior = r.HitTestBehavior.opaque, child = body, onLongPress = function()
				if chat:pick(line) then s.HapticFeedback.lightImpact() end
			end})
		end
		table.insert(messages, w.KeyedSubtree({key = w.ValueKey({value = "line:" .. line.key}), child = body}))
	end
	local first = entry.lines[1]
	table.insert(messages, 1, ChatLine.speaker(first))
	local head = ChatLine.head(first, HEAD)
	if Roster.linkable({player = first.player, mine = entry.mine}) then
		head = Pressable({label = first.name, depth = 0.12, child = head,
			onTap = function() game.openLink(Roster.profile(first), true) end})
	end
	return w.Padding({padding = p.EdgeInsets.only({right = 32}), child = w.Row({crossAxisAlignment = w.CrossAxisAlignment.start,
		children = {
			head,
			w.SizedBox({width = 8}),
			w.Flexible({child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.start,
				children = messages})}),
		}})})
end

local function history(self: State, height: number): w.Widget
	local chat = self.widget.chat
	local body: w.Widget
	if #chat.lines == 0 then
		body = w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 18, vertical = 22}), child = w.Text({
			data = ChatText.chatEmpty, textAlign = ui.TextAlign.center, style = p.TextStyle({fontSize = 13, color = HINT})})})
	else
		local groups = groupsOf(chat)
		body = w.ListView.builder({reverse = true, shrinkWrap = true,
			padding = p.EdgeInsets.fromLTRB(12, 12, 12, 8), itemCount = #groups,
			itemBuilder = function(_: w.BuildContext, index: number): w.Widget
				local entry = groups[#groups - index]
				return w.Padding({key = w.ValueKey({value = "group:" .. entry.lines[1].key}),
					padding = p.EdgeInsets.symmetric({vertical = 4}), child = group(chat, entry)})
			end})
	end
	return w.ConstrainedBox({constraints = r.BoxConstraints({maxHeight = height}), child = body})
end

local function historyButton(self: State): w.Widget
	-- The icon (x 10-30, y 14-34) sits as far from the bar's edge as the
	-- field's text does from it.
	return Pressable({label = ChatText.chatHistory, depth = 0.12, onTap = function() toggle(self) end,
		child = w.SizedBox({width = 40, height = 48, child = w.Center({child = w.Icon({
			icon = if self.open then mdi.chevronDown else mdi.chatOutline, size = 20,
			color = if self.open then ACCENT else HINT})})})})
end

local function bar(self: State): w.Widget
	local strings = ChatText
	local accepted = self.widget.chat:rulesAccepted()
	return w.Padding({padding = p.EdgeInsets.only({left = 4}), child = w.Row({children = {
		historyButton(self),
		w.SizedBox({width = 4}),
		-- Before the chat rules are accepted, a tap on the field shows them
		-- instead of the keyboard.
		w.Expanded({child = w.GestureDetector({behavior = r.HitTestBehavior.opaque,
			onTap = if accepted then nil else function() afterRules(self, function() self.focus:requestFocus() end) end,
			child = w.IgnorePointer({ignoring = not accepted, child = m.TextField({controller = self.input, focusNode = self.focus,
				key = w.ValueKey({value = "chat"}),
				style = p.TextStyle({fontSize = 14, color = WHITE}), cursorColor = ACCENT,
				textInputAction = s.TextInputAction.send, inputFormatters = {self.formatter},
				onChanged = function(text: string) self.widget.chat:typed(text) end,
				-- Without this, the send action drops focus before onSubmitted.
				onEditingComplete = function() end,
				onSubmitted = function(text: string) submit(self, text) end,
				decoration = m.InputDecoration({hintText = strings.chatHint,
					hintStyle = p.TextStyle({fontSize = 14, color = HINT}),
					-- Every state borderless: the glass bar is the only edge.
					border = m.InputBorder.none, enabledBorder = m.InputBorder.none,
					focusedBorder = m.InputBorder.none, disabledBorder = m.InputBorder.none,
					filled = false, isDense = true, contentPadding = p.EdgeInsets.zero})})})})}),
		Pressable({key = w.ValueKey({value = "chat-emoji"}), label = strings.emojiButton, depth = 0.12,
			onTap = function()
				if accepted then togglePicker(self) else afterRules(self, function() togglePicker(self) end) end
			end,
			child = w.SizedBox({width = 34, height = 48, child = w.Center({child = w.Icon({
				icon = mdi.emoticonOutline, size = 20, color = if self.picking then ACCENT else HINT})})})}),
		-- A light tap of haptics when the message goes out.
		Pressable({key = w.ValueKey({value = "chat-send"}), label = strings.send, depth = 0.12,
			onTap = function() if submit(self, self.input.text) then s.HapticFeedback.lightImpact() end end,
			child = w.Padding({padding = p.EdgeInsets.all(6), child = w.Container({width = 36, height = 36,
				decoration = p.BoxDecoration({color = ACCENT, shape = p.BoxShape.circle}),
				child = w.Icon({icon = mdi.arrowUp, size = 18, color = INK})})})}),
	}})})
end

-- What is open above the field, closed off from it by a hairline.
-- How tall a panel may be: part of the screen, so it never takes over a
-- phone. With the keyboard up there is little left, and it takes less.
local function panelHeight(context: w.BuildContext): number
	local media = w.MediaQuery.of(context)
	local keyboard = media.viewInsets.bottom
	local room = media.size.height - keyboard - media.padding.top
	if keyboard > 0 then return math.clamp(room * 0.3, 120, 180) end
	return math.clamp(room * 0.38, 120, 260)
end

local function panel(self: State, height: number): w.Widget
	local inside: w.Widget
	if self.open then
		inside = history(self, height)
	elseif self.picking then
		inside = EmojiPicker({height = height, onPick = function(emoji: Emojis.Emoji) pick(self, emoji) end})
	else
		return w.SizedBox.shrink({key = w.ValueKey({value = "none"})})
	end
	return w.Column({key = w.ValueKey({value = if self.open then "history" else "emoji"}), mainAxisSize = w.MainAxisSize.min,
		crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
			inside,
			w.Container({height = 1, margin = p.EdgeInsets.symmetric({horizontal = 12}), color = DIVIDER}),
		}})
end

return define("ChatBar", {
	createState = function(): Fields
		local input, inputEmojis = EmojiInput.controller(14)
		return { input = input, focus = w.FocusNode({}), formatter = EmojiInput.formatter(), open = false, picking = false, reopen = false,
			changed = nil, emojis = nil, roles = nil, inputEmojis = inputEmojis, dismiss = nil, focused = function() end,
			card = nil, below = 0, covered = nil }
	end,
	initState = function(self: State)
		self.open = self.widget.expanded == true
		local changed = function()
			if not self.mounted then return end
			self:setState(function() end)
		end
		self.changed = changed
		self.widget.chat.onLinesChanged = changed
		self.focused = changed
		self.focus:addListener(changed)
		-- A tap on the game while typing only ends the typing (gameplay/Controls).
		local dismiss = function(): boolean
			if not self.mounted then return false end
			local typing, picking = self.focus.hasFocus, self.picking
			if typing then self.focus:unfocus() end
			if picking then self:setState(function() closePicker(self) end) end
			return typing or picking
		end
		self.dismiss = dismiss
		self.widget.chat.dismissInput = dismiss
		-- Read as a finger lands on the game, mid-animation too: the joystick
		-- strip stays above the card (gameplay/Controls).
		local covered = function(): number
			local card = self.card
			if not self.mounted or not card or not card.mounted then return 0 end
			-- A size is only there once laid out.
			local ok, size = pcall(function(): ui.Size? return card.size end)
			return if ok and size then size.height + self.below else 0
		end
		self.covered = covered
		self.widget.chat.covered = covered
		-- Lines that came before the emoji or role catalogs draw their emoji
		-- and roles once each loads.
		local redraw = function()
			if self.mounted and self.open then self:setState(function() end) end
		end
		self.emojis = Emojis.subscribe(redraw)
		self.roles = Roles.subscribe(redraw)
		Emojis.load()
		Roles.load()
	end,
	dispose = function(self: State)
		if self.widget.chat.onLinesChanged == self.changed then
			self.widget.chat.onLinesChanged = nil
		end
		if self.widget.chat.dismissInput == self.dismiss then
			self.widget.chat.dismissInput = nil
		end
		if self.widget.chat.covered == self.covered then
			self.widget.chat.covered = nil
		end
		if self.emojis then self.emojis() end
		if self.roles then self.roles() end
		self.inputEmojis()
		self.focus:removeListener(self.focused)
		self.input:dispose()
		self.focus:dispose()
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		-- One card: the panel grows out of its top (the outgoing one fading,
		-- kept to the bottom so it leaves into the bar), the field below.
		local card = w.Container({decoration = p.BoxDecoration({color = GLASS,
			borderRadius = p.BorderRadius.circular(RADIUS), border = p.Border.all({color = GLASS_LINE})}),
			child = w.ClipRRect({borderRadius = p.BorderRadius.circular(RADIUS - 1), child = w.Column({
				mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
					w.AnimatedSize({duration = GROW, curve = animation.Curves.easeOutCubic, alignment = p.Alignment.bottomCenter,
						child = w.AnimatedSwitcher({duration = FADE, child = panel(self, panelHeight(context)),
							layoutBuilder = function(current: w.Widget?, previous: {read w.Widget}): w.Widget
								local stack: {w.Widget} = {}
								for _, child in previous do table.insert(stack, child) end
								if current then table.insert(stack, current) end
								return w.Stack({alignment = p.Alignment.bottomCenter, children = stack})
							end})}),
					-- Keyed, so the field is never made anew: a new one would drop
					-- the old one's input connection, and the keyboard with it.
					w.KeyedSubtree({key = w.ValueKey({value = "chat-bar"}), child = bar(self)}),
				}})})})
		-- Rides on top of the on-screen keyboard. Flutter takes the keyboard out
		-- of the safe-area padding while it is up, so the two never stack.
		local keyboard = w.MediaQuery.viewInsetsOf(context).bottom
		-- A 12 px margin, or the safe area where that is wider: the bar sits
		-- right on the home indicator's strip, never in it (the system's swipes).
		self.below = keyboard + math.max(w.MediaQuery.paddingOf(context).bottom, MARGIN)
		-- Only the bar and what opens above it take touches; the rest of the
		-- screen walks. A tap anywhere in them (history, emoji, Send) leaves
		-- the field focused, its keyboard up.
		return w.Padding({padding = p.EdgeInsets.only({bottom = keyboard}), child = w.Align({
			alignment = p.Alignment.bottomLeft, child = w.SafeArea({minimum = p.EdgeInsets.all(MARGIN),
				child = w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = 420}),
					child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
						if self.widget.hint and not (self.open or self.picking or self.focus.hasFocus)
							then w.IgnorePointer({child = w.Padding({padding = p.EdgeInsets.only({bottom = 12}),
								child = w.Center({child = self.widget.hint})})})
							else w.SizedBox.shrink({}),
						w.TextFieldTapRegion({child = w.Builder({builder = function(cardContext: w.BuildContext): w.Widget
							self.card = cardContext
							return card
						end})}),
					}})})})})})
	end,
})
