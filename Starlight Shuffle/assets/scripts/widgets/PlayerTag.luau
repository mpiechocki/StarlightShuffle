--!strict
--@client
-- A player's name as the mini-games show it under their own figures: in the
-- name style and on the plate they wear from the shop (client/Looks, kept
-- from everyone's avatar identity), animated while it moves (unless motion is
-- reduced), or a plain dark pill for a player who wears nothing. It follows
-- the player's look as it changes, so the same name looks the same in the
-- lobby and in every mini-game. Functional lists (scores, results) keep plain
-- text instead.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local fonts = require("@fonts/app")
local Shop = require("../shared/Shop")
local Looks = require("../client/Looks")
local Cosmetics = require("./Cosmetics")

local PILL = ui.Color({value = 0xd91b1636})
local EDGE = ui.Color({value = 0x40ffffff})

type Props = {
	read key: w.Key?,
	read player: number?, -- account id
	read name: string,
	read size: number?, -- points (11 by default)
	read maxWidth: number?,
}
type Fields = { look: Shop.Look?, onChange: (() -> ())?, onTick: (() -> ())?, ticking: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local function moves(look: Shop.Look?): boolean
	return look ~= nil and Looks.moving(look.names, look.plates)
end

-- Ticks with Looks' ticker only while the look moves.
local function tick(self: State, on: boolean)
	if on == self.ticking then return end
	self.ticking = on
	Looks.watch(on)
	local listener = self.onTick
	if not listener then return end
	if on then Looks.ticker:addListener(listener) else Looks.ticker:removeListener(listener) end
end

local function plainTag(text: string, size: number, maxWidth: number): w.Widget
	return w.Container({constraints = r.BoxConstraints({maxWidth = maxWidth}), padding = p.EdgeInsets.fromLTRB(7, 2, 7, 3),
		decoration = p.BoxDecoration({color = PILL, borderRadius = p.BorderRadius.circular(99), border = p.Border.all({color = EDGE})}),
		child = w.Text({data = text, maxLines = 1, overflow = w.TextOverflow.ellipsis, softWrap = false, textAlign = ui.TextAlign.center,
			style = p.TextStyle({fontFamily = fonts.lato, fontSize = size, fontWeight = ui.FontWeight.w800, color = ui.Color({value = 0xfffaf6ff})})})})
end

return define("PlayerTag", {
	createState = function(): Fields return { look = nil, onChange = nil, onTick = nil, ticking = false } end,
	initState = function(self: State)
		self.look = Looks.of(self.widget.player)
		self.onTick = function() if self.mounted then self:setState(function() end) end end
		local onChange = function()
			if not self.mounted then return end
			local look = Looks.of(self.widget.player)
			if look ~= self.look then
				self:setState(function() self.look = look end)
				tick(self, moves(look))
			end
		end
		self.onChange = onChange
		Looks.changed:addListener(onChange)
		tick(self, moves(self.look))
	end,
	didUpdateWidget = function(self: State, old: Props)
		if old.player ~= self.widget.player then
			self.look = Looks.of(self.widget.player)
			tick(self, moves(self.look))
		end
	end,
	dispose = function(self: State)
		tick(self, false)
		if self.onChange then Looks.changed:removeListener(self.onChange) end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local size, maxWidth = self.widget.size or 11, self.widget.maxWidth or 140
		local look = self.look
		if not look or (look.names == Shop.DEFAULTS.names and look.plates == Shop.DEFAULTS.plates) then
			return plainTag(self.widget.name, size, maxWidth)
		end
		local t = if Looks.isStill() then 0 else Looks.time()
		local plated = Looks.plate(look.plates) ~= nil
		local label = Cosmetics.label(self.widget.name, look.names, if plated then look.plates else nil, t, size, nil, maxWidth)
		if plated then return label end
		-- A name style alone: on the dark pill, so a light colour stays readable.
		return w.Container({constraints = r.BoxConstraints({maxWidth = maxWidth}), padding = p.EdgeInsets.fromLTRB(7, 2, 7, 3),
			decoration = p.BoxDecoration({color = PILL, borderRadius = p.BorderRadius.circular(99), border = p.Border.all({color = EDGE})}),
			child = label})
	end,
})
