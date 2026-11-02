--!strict
--@client
-- The chat's layers of the HUD (client/Chat), shown in the lobby and during a
-- cycle's breaks back in the lobby scene: not while a mini-game is on. `under` is what goes beneath the HUD (name tags
-- and speech bubbles over avatars, the latest lines along the top left under
-- the head, and the chat bar along the bottom, with the lobby's hint above it:
-- tap the arcade to check in for the next mini-game, or once checked in, how
-- many of the Games.MIN_PLAYERS needed are, or with a cycle running, that you
-- join its next mini-game); `over` is what goes above it
-- (a long-pressed message's menu, and the chat rules before a first message).
-- Hiding them closes the keyboard, and the chat goes quiet (Chat.quiet): no
-- bubbles or typing left over for the next break. During a mini-game only
-- the name tags of players wearing a shop look stay (client/Chat's
-- cosmeticOnly, set by the root).
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
local Games = require("../shared/Games")

-- The HUD's head (12 margin, a 52 tall row, a gap): the feed starts below it.
local FEED_TOP = 12 + 52 + 8
-- Whether the chat shows: in the lobby, and on a cycle's break.
local function chatting(place: Place.Controller): boolean
	local round = place.round
	return place.place == "lobby" or (place.place == "cycle" and round ~= nil and round.phase == "break")
end

-- The lobby's hint, or nil: not while the HUD has a notice there, nor over
-- the leaderboard, nor on a break (there is no arcade to tap).
local function hintText(place: Place.Controller): string?
	if place.place ~= "lobby" or place.moving or place.failed or place.boardOpen or not place:online() then return nil end
	local count, need = place.readyCount, Games.MIN_PLAYERS
	-- A cycle is running: no count to reach, you join its next mini-game.
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

type Props = { read place: Place.Controller, read chat: Chat.Controller, read layer: "under" | "over" }
type Fields = { unlisten: (() -> ())?, lobby: boolean, hint: string? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

return define("LobbyChat", {
	createState = function(): Fields return { unlisten = nil, lobby = false, hint = nil } end,
	initState = function(self: State)
		local place = self.widget.place
		self.lobby, self.hint = chatting(place), hintText(place)
		-- Rebuilt only when the chat or the hint comes or goes, not on every HUD change.
		self.unlisten = place:listen(function()
			local lobby, shown = chatting(place), hintText(place)
			if self.mounted and (lobby ~= self.lobby or shown ~= self.hint) then
				if self.lobby and not lobby and self.widget.layer == "under" then self.widget.chat:quiet() end
				self:setState(function() self.lobby, self.hint = lobby, shown end)
			end
		end)
	end,
	dispose = function(self: State)
		if self.unlisten then self.unlisten(); self.unlisten = nil end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local chat = self.widget.chat
		if not self.lobby then
			if self.widget.layer == "under" and self.widget.place.place == "cycle" then
				return w.IgnorePointer({child = w.RepaintBoundary({child = PlayerLabels({chat = chat})})})
			end
			return w.SizedBox.shrink({})
		end
		local children: {w.Widget} = if self.widget.layer == "under" then {
			w.IgnorePointer({child = w.RepaintBoundary({child = PlayerLabels({chat = chat})})}),
			w.RepaintBoundary({child = ChatFeed({chat = chat, top = FEED_TOP})}),
			ChatBar({chat = chat, hint = if self.hint then hint(self.hint, self.widget.place.ready) else nil}),
		} else {
			MessageMenu({chat = chat}),
			ChatRules({chat = chat}),
		}
		return w.Stack({fit = w.StackFit.expand, children = children})
	end,
})
