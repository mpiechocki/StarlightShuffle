--!strict
--@client
-- The chat's layers of the HUD (client/Chat). In the lobby: `under` is what
-- goes beneath the HUD (name tags
-- and speech bubbles over avatars, the latest lines along the top left under
-- the head, and the chat bar along the bottom, with the lobby's hint above it:
-- tap the arcade to check in for the next mini-game, or once checked in, how
-- many of the Games.MIN_PLAYERS needed are, or with a mini-game on or counting
-- down, that you join the next one); `over` is what goes above it
-- (a long-pressed message's menu, and the chat rules before a first message).
-- In a mini-game the chat is the same one (client/Chat), put away until the
-- HUD's chat button opens it: then all of it goes over everything, the
-- history open, on a dimmed backdrop; a tap on the backdrop or its close
-- button puts it away.
-- Hiding them closes the keyboard, and the chat goes quiet (Chat.quiet): no
-- bubbles or typing left over for the lobby. During a mini-game only
-- the name tags of players wearing a shop look stay (client/Chat's
-- cosmeticOnly, set by the root).
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
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
local Games = require("../shared/Games")

-- The HUD's head (12 margin, a 52 tall row, a gap): the feed starts below it.
local FEED_TOP = 12 + 52 + 8
-- Where the feed starts: under the head, and under the admins' lineup button
-- when it sits below the Starlights pill (the lobby's countdown: widgets/Hud).
local function feedTop(place: Place.Controller): number
	local round = place.round
	if place.lineup and round and round.phase == "break" then return FEED_TOP + 38 + 8 end
	return FEED_TOP
end

-- Whether the chat shows: in the lobby.
local function chatting(place: Place.Controller): boolean
	return place.place == "lobby"
end

-- The lobby's hint, or nil: not while the HUD has a notice there, nor over
-- the leaderboard.
local function hintText(place: Place.Controller): string?
	if place.place ~= "lobby" or place.moving or place.failed or place.boardOpen or not place:online() then return nil end
	local count, need = place.readyCount, Games.MIN_PLAYERS
	-- Counting down to the next mini-game (the head says which, and when).
	local round = place.round
	if round and round.phase == "break" then
		if place.ready then return "You're in for the next mini-game · tap the arcade to sit it out" end
		return "Tap the arcade to join the next mini-game"
	end
	-- A group from here is playing: no count to reach, you go with them next.
	if place.cycleRunning then
		local on = Games.get(place.cycleGame)
		local now = if on then " · " .. on.title .. " is on now" else ""
		if place.ready then return "You're in! You'll join the next mini-game" .. now .. " · tap the arcade to leave" end
		return "Tap the arcade to join the next mini-game" .. now
	end
	if place.ready then
		local more = need - count
		if more <= 0 then return "You're in! Starting…" end
		return "You're in! " .. count .. " of " .. need .. " ready · waiting for " .. more
			.. (if more == 1 then " more player" else " more players") .. " · tap the arcade to leave"
	end
	if count > 0 then return "Tap the arcade to join the next mini-game · " .. count .. " of " .. need .. " ready" end
	return "Tap the arcade to join the next mini-game"
end

local function hint(text: string, ready: boolean): w.Widget
	return Style.card(w.Row({mainAxisSize = w.MainAxisSize.min, children = {
		w.Icon({icon = if ready then material.check_circle_rounded else material.star_rounded, size = 18, color = Style.GOLD}),
		w.SizedBox({width = 8}),
		w.Flexible({child = Style.text(text, Style.style(14, Style.WHITE, ui.FontWeight.w600), 3)}),
	}}), p.EdgeInsets.symmetric({horizontal = 16, vertical = 10}), 999)
end

-- The chat opened over a mini-game: a dimmed backdrop that puts it away, the
-- bar with its history open, a close button where the chat button was, and
-- the message menu and chat rules over them.
local function overGame(chat: Chat.Controller): w.Widget
	return w.Stack({fit = w.StackFit.expand, children = {
		w.GestureDetector({key = w.ValueKey({value = "chat-backdrop"}), behavior = r.HitTestBehavior.opaque,
			onTap = function() chat:setOpen(false) end,
			child = w.Container({color = ui.Color({value = 0x8c0b0a18})})}),
		ChatBar({chat = chat, expanded = true}),
		-- Where the HUD's chat button is: left of Pause/Play (52 wide), in the head's 52 tall row.
		w.SafeArea({child = w.Padding({padding = p.EdgeInsets.only({top = 12 + 4, right = 12 + 52 + 8}),
			child = w.Align({alignment = p.Alignment.topRight, child = w.GestureDetector({key = w.ValueKey({value = "chat-close"}),
				onTap = function() chat:setOpen(false) end,
				child = w.Container({width = 44, height = 44,
					decoration = p.BoxDecoration({color = Style.GOLD, shape = p.BoxShape.circle}),
					child = w.Icon({icon = material.close_rounded, size = 21, color = Style.INK})})})})})}),
		MessageMenu({chat = chat}),
		ChatRules({chat = chat}),
	}})
end

type Props = { read place: Place.Controller, read chat: Chat.Controller, read layer: "under" | "over" }
type Fields = { unlisten: (() -> ())?, unwatch: (() -> ())?, lobby: boolean, hint: string?, open: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

return define("LobbyChat", {
	createState = function(): Fields return { unlisten = nil, unwatch = nil, lobby = false, hint = nil, open = false } end,
	initState = function(self: State)
		local place, chat = self.widget.place, self.widget.chat
		self.lobby, self.hint = chatting(place), hintText(place)
		self.open = place.place == "cycle" and chat.open
		-- Opened or put away over a mini-game.
		self.unwatch = chat:watch(function()
			local open = place.place == "cycle" and chat.open
			if self.mounted and open ~= self.open then self:setState(function() self.open = open end) end
		end)
		-- Rebuilt only when the chat or the hint comes or goes, not on every HUD change.
		self.unlisten = place:listen(function()
			local lobby, shown = chatting(place), hintText(place)
			local open = place.place == "cycle" and chat.open
			if self.mounted and (lobby ~= self.lobby or shown ~= self.hint or open ~= self.open) then
				if self.lobby and not lobby and self.widget.layer == "under" then chat:quiet() end
				self:setState(function() self.lobby, self.hint, self.open = lobby, shown, open end)
			end
		end)
	end,
	dispose = function(self: State)
		if self.unlisten then self.unlisten(); self.unlisten = nil end
		if self.unwatch then self.unwatch(); self.unwatch = nil end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local chat = self.widget.chat
		if not self.lobby then
			if self.widget.layer == "under" and self.widget.place.place == "cycle" then
				return w.IgnorePointer({child = w.RepaintBoundary({child = PlayerLabels({chat = chat})})})
			end
			if self.widget.layer == "over" and self.open then return overGame(chat) end
			return w.SizedBox.shrink({})
		end
		local children: {w.Widget} = if self.widget.layer == "under" then {
			w.IgnorePointer({child = w.RepaintBoundary({child = PlayerLabels({chat = chat})})}),
			w.RepaintBoundary({child = ChatFeed({chat = chat, top = feedTop(self.widget.place)})}),
			ChatBar({chat = chat, hint = if self.hint then hint(self.hint, self.widget.place.ready) else nil}),
		} else {
			MessageMenu({chat = chat}),
			ChatRules({chat = chat}),
		}
		return w.Stack({fit = w.StackFit.expand, children = children})
	end,
})
