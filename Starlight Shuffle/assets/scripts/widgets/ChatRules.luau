--!strict
--@client
-- The chat's ground rules, over a scrim, the first time a player on this
-- device goes to chat (Chat.askRules): be kind, keep personal info private,
-- chat is moderated, and how to report a message. Accepting them is kept on
-- the device (Chat.acceptRules) and goes on to the chat; a tap outside puts
-- them away until the next try.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local core = require("@dart/core")
local animation = require("@flutter/animation")
local mdi = require("@icons/mdi")
local Chat = require("../client/Chat")
local ChatText = require("../client/ChatText")
local Style = require("./ChatStyle")
local InfoCard = require("./InfoCard")

local POP = core.Duration({milliseconds = 140})

type Props = { read chat: Chat.Controller }
type Fields = { changed: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

return define("ChatRules", {
	createState = function(): Fields return { changed = nil } end,
	initState = function(self: State)
		local changed = function()
			if self.mounted then self:setState(function() end) end
		end
		self.changed = changed
		self.widget.chat.onRules = changed
	end,
	dispose = function(self: State)
		if self.widget.chat.onRules == self.changed then self.widget.chat.onRules = nil end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local chat = self.widget.chat
		-- Not asked: no scrim, and touches reach the game.
		if not chat.rulesNext then return w.SizedBox.shrink({}) end
		local strings = ChatText
		local card = InfoCard.card({title = strings.chatRulesTitle, intro = strings.chatRulesIntro,
			accept = strings.chatRulesAccept, key = "chat-rules-accept", onAccept = function() chat:acceptRules() end,
			rows = {
				{mark = InfoCard.icon(mdi.heartOutline), title = strings.chatRulesKind, detail = InfoCard.detail(strings.chatRulesKindDetail)},
				{mark = InfoCard.icon(mdi.lockOutline), title = strings.chatRulesPrivate,
					detail = InfoCard.detail(strings.chatRulesPrivateDetail)},
				{mark = InfoCard.icon(mdi.shieldCheckOutline), title = strings.chatRulesModerated,
					detail = InfoCard.detail(strings.chatRulesModeratedDetail)},
				{mark = InfoCard.icon(mdi.flagOutline), title = strings.chatRulesReport,
					detail = InfoCard.detail(strings.chatRulesReportDetail)},
			}})
		-- Fades in, growing a little, as the message menu does.
		return w.GestureDetector({key = w.ValueKey({value = "chat-rules"}), behavior = r.HitTestBehavior.opaque,
			onTap = function() chat:askRules(nil) end, child = w.TweenAnimationBuilder({
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
