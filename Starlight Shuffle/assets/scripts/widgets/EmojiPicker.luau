--!strict
--@client
-- The app's custom emoji, shown in the chat bar's card above its field so
-- picks show up there as they are made. Each tap passes the emoji to
-- [onPick]; it loads the catalog if needed and offers a retry when that fails.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local m = require("@flutter/material")
local ui = require("@dart/ui")
local es = require("@es/ui")
local Emojis = require("../client/Emojis")
local EmojiCodes = require("../shared/EmojiCodes")
local ChatText = require("../client/ChatText")
local Pressable = require("./Pressable")

local function color(value: number): ui.Color return ui.Color({value = value}) end
local HINT = color(0xb3ffffff)
local ACCENT = color(0xffb0a8ea)

type Props = { read height: number, read onPick: (Emojis.Emoji) -> () }
type Fields = { unsubscribe: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local function message(text: string): w.Widget
	return w.Text({data = text, textAlign = ui.TextAlign.center, style = p.TextStyle({fontSize = 13, color = HINT})})
end

local function contents(self: State): w.Widget
	local status = Emojis.status()
	local strings = ChatText
	if status == "failed" then
		return w.Center({child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
			message(strings.emojiFailed),
			w.SizedBox({height = 12}),
			Pressable({key = w.ValueKey({value = "emoji-retry"}), label = strings.retry,
				onTap = function() Emojis.load(); self:setState(function() end) end,
				child = w.Container({padding = p.EdgeInsets.symmetric({horizontal = 16, vertical = 8}),
					decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(99), border = p.Border.all({color = ACCENT})}),
					child = w.Text({data = strings.retry, style = p.TextStyle({fontSize = 13, fontWeight = ui.FontWeight.w700, color = ACCENT})})})}),
		}})})
	end
	if status ~= "ready" then return w.Center({child = es.LoadingIndicator({})}) end
	local emojis = Emojis.all()
	if #emojis == 0 then return w.Center({child = message(strings.emojiNone)}) end
	return w.GridView.builder({padding = p.EdgeInsets.all(8),
		gridDelegate = w.SliverGridDelegateWithMaxCrossAxisExtent({maxCrossAxisExtent = 46, mainAxisSpacing = 2, crossAxisSpacing = 2}),
		itemCount = #emojis, itemBuilder = function(_: w.BuildContext, index: number): w.Widget
			local emoji = emojis[index + 1]
			local code = EmojiCodes.code(emoji.name)
			return m.Tooltip({message = code, child = Pressable({key = w.ValueKey({value = "emoji-" .. emoji.name}),
				label = code, depth = 0.18, onTap = function() self.widget.onPick(emoji) end,
				child = w.Padding({padding = p.EdgeInsets.all(6), child = es.WebImage({url = emoji.url, fit = p.BoxFit.contain,
					showLoading = false})})})})
		end})
end

return define("EmojiPicker", {
	createState = function(): Fields return { unsubscribe = nil } end,
	initState = function(self: State)
		self.unsubscribe = Emojis.subscribe(function()
			if self.mounted then self:setState(function() end) end
		end)
		Emojis.load()
	end,
	dispose = function(self: State)
		if self.unsubscribe then self.unsubscribe() end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		-- A tap in here leaves the chat bar's field focused (its keyboard up).
		return w.TextFieldTapRegion({child = w.SizedBox({key = w.ValueKey({value = "emoji-picker"}),
			height = self.widget.height, child = contents(self)})})
	end,
})
