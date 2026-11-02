--!strict
--@client
-- The chat's layers of the HUD (client/Chat), shown only in the lobby: the
-- mini-game cycle has no chat. `under` is what goes beneath the HUD (name tags
-- and speech bubbles over avatars, the latest lines along the top left under
-- the head, and the chat bar along the bottom, with the hint pointing at the
-- arcade above it); `over` is what goes above it
-- (a long-pressed message's menu, and the chat rules before a first message).
-- Leaving the lobby unmounts them, which closes the keyboard.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local material = require("@icons/material")
local Chat = require("../client/Chat")
local Place = require("../client/Place")
local PlayerLabels = require("./PlayerLabels")
local ChatFeed = require("./ChatFeed")
local ChatBar = require("./ChatBar")
local MessageMenu = require("./MessageMenu")
local ChatRules = require("./ChatRules")
local Style = require("./Style")

-- The HUD's head (12 margin, a 52 tall row, a gap): the feed starts below it.
local FEED_TOP = 12 + 52 + 8
-- Whether the hint shows: not while the HUD has a notice there, nor over the
-- leaderboard.
local function hinting(place: Place.Controller): boolean
	return not place.moving and not place.failed and not place.boardOpen and place:online()
end

local function hint(): w.Widget
	return Style.card(w.Row({mainAxisSize = w.MainAxisSize.min, children = {
		w.Icon({icon = material.star_rounded, size = 18, color = Style.GOLD}),
		w.SizedBox({width = 8}),
		w.Flexible({child = Style.text("Tap the arcade to start the mini-games", Style.style(14, Style.WHITE, ui.FontWeight.w600), 2)}),
	}}), p.EdgeInsets.symmetric({horizontal = 16, vertical = 10}), 999)
end

type Props = { read place: Place.Controller, read chat: Chat.Controller, read layer: "under" | "over" }
type Fields = { unlisten: (() -> ())?, lobby: boolean, hint: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

return define("LobbyChat", {
	createState = function(): Fields return { unlisten = nil, lobby = false, hint = false } end,
	initState = function(self: State)
		local place = self.widget.place
		self.lobby, self.hint = place.place == "lobby", hinting(place)
		-- Rebuilt only when the place or the hint changes, not on every HUD change.
		self.unlisten = place:listen(function()
			local lobby, shown = place.place == "lobby", hinting(place)
			if self.mounted and (lobby ~= self.lobby or shown ~= self.hint) then
				self:setState(function() self.lobby, self.hint = lobby, shown end)
			end
		end)
	end,
	dispose = function(self: State)
		if self.unlisten then self.unlisten(); self.unlisten = nil end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		if not self.lobby then return w.SizedBox.shrink({}) end
		local chat = self.widget.chat
		local children: {w.Widget} = if self.widget.layer == "under" then {
			w.IgnorePointer({child = w.RepaintBoundary({child = PlayerLabels({chat = chat})})}),
			w.RepaintBoundary({child = ChatFeed({chat = chat, top = FEED_TOP})}),
			ChatBar({chat = chat, hint = if self.hint then hint() else nil}),
		} else {
			MessageMenu({chat = chat}),
			ChatRules({chat = chat}),
		}
		return w.Stack({fit = w.StackFit.expand, children = children})
	end,
})
