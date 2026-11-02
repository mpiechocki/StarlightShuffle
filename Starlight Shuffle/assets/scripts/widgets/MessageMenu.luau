--!strict
--@client
-- What a long press on someone else's message in the chat history offers
-- (Chat.pick): the message as it was said, over a scrim, and what can be done
-- with it. Reporting it opens the app's report sheet over the game
-- (Chat.report). A tap outside, or Cancel, puts it away.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local core = require("@dart/core")
local animation = require("@flutter/animation")
local mdi = require("@icons/mdi")
local Chat = require("../client/Chat")
local ChatText = require("../client/ChatText")
local Style = require("./ChatStyle")
local ChatLine = require("./ChatLine")

local HEAD = 32
local POP = core.Duration({milliseconds = 140})

type Props = { read chat: Chat.Controller }
type Fields = { changed: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

-- The message, as the history shows it.
local function preview(line: Chat.Line): w.Widget
	return Style.card(w.Row({crossAxisAlignment = w.CrossAxisAlignment.start, children = {
		ChatLine.head(line, HEAD),
		w.SizedBox({width = 10}),
		w.Flexible({child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.start,
			children = {ChatLine.speaker(line), ChatLine.message(line)}})}),
	}}))
end

return define("MessageMenu", {
	createState = function(): Fields return { changed = nil } end,
	initState = function(self: State)
		local changed = function()
			if self.mounted then self:setState(function() end) end
		end
		self.changed = changed
		self.widget.chat.onPicked = changed
	end,
	dispose = function(self: State)
		if self.widget.chat.onPicked == self.changed then self.widget.chat.onPicked = nil end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local chat = self.widget.chat
		local line = chat.picked
		-- Nothing picked: no scrim, and touches reach the game.
		if not line then return w.SizedBox.shrink({}) end
		local function cancel() chat:pick(nil) end
		local strings = ChatText
		local card = w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = 340}),
			child = w.Container({padding = p.EdgeInsets.all(18), decoration = p.BoxDecoration({color = Style.SURFACE,
				borderRadius = p.BorderRadius.circular(24), border = p.Border.all({color = Style.LINE})}),
				child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
					preview(line),
					w.SizedBox({height = 14}),
					Style.button({label = strings.reportMessage, icon = mdi.flagOutline, kind = "danger", height = 46,
						key = "message-report", onTap = function() chat:report(line) end}),
					w.SizedBox({height = 8}),
					Style.button({label = strings.cancel, kind = "quiet", height = 46, key = "message-cancel", onTap = cancel}),
				}})})})
		-- Fades in, growing a little, each time a message is picked.
		return w.GestureDetector({key = w.ValueKey({value = "message-menu"}), behavior = r.HitTestBehavior.opaque,
			onTap = cancel, child = w.TweenAnimationBuilder({key = w.ValueKey({value = "picked:" .. line.key}),
				tween = animation.Tween({begin = 0, ["end"] = 1}), duration = POP, curve = animation.Curves.easeOutCubic,
				builder = function(_: w.BuildContext, value: number, child: w.Widget?): w.Widget
					return w.Opacity({opacity = value, child = child})
				end,
				child = w.Container({color = Style.SCRIM, alignment = p.Alignment.center, padding = p.EdgeInsets.all(24),
					child = w.GestureDetector({behavior = r.HitTestBehavior.opaque, onTap = function() end,
						child = w.TweenAnimationBuilder({tween = animation.Tween({begin = 0.96, ["end"] = 1}), duration = POP,
							curve = animation.Curves.easeOutCubic,
							builder = function(_: w.BuildContext, scale: number, child: w.Widget?): w.Widget
								return w.Transform.scale({scale = scale, child = child})
							end, child = card})})})})})
	end,
})
