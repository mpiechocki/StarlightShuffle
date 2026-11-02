--!strict
--@client
-- A tappable that answers the finger: it sinks quickly while pressed and
-- springs back with a slight overshoot when let go. A quick tap, whose press
-- and release can land in the same frame, still dips and returns: the
-- animation runs through a phase number that only ever counts up (even at
-- rest, odd pressed), so letting go always travels through "fully pressed"
-- from wherever the press had got to. Only a scale animates, so a press never
-- rebuilds what is inside. Without onTap it does nothing; the caller shows it
-- disabled.
local w = require("@flutter/widgets")
local r = require("@flutter/rendering")
local core = require("@dart/core")
local animation = require("@flutter/animation")

local DOWN = core.Duration({milliseconds = 90})
local UP = core.Duration({milliseconds = 260})

export type Props = {
	read key: w.Key?,
	read onTap: (() -> ())?,
	read child: w.Widget,
	-- How much smaller it gets when fully pressed (0.06: to 94%).
	read depth: number?,
	-- For assistive technology; selected for choices.
	read label: string?,
	read selected: boolean?,
}
type Fields = { phase: number }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

-- How far pressed (0..1, a little under 0 while overshooting) at [value].
local function pressed(value: number): number
	local segment = math.floor(value)
	local f = value - segment
	if segment % 2 == 0 then return 1 - (1 - f) ^ 3 end -- sinking: an ease-out-cubic
	local u = f - 1 -- rising: an ease-out-back
	return 1 - (1 + 2.70158 * u * u * u + 1.70158 * u * u)
end

return define("Pressable", {
	createState = function(): Fields return { phase = 0 } end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local props = self.widget
		local onTap = props.onTap
		local depth = props.depth or 0.06
		local function press(on: boolean)
			if not self.mounted or (self.phase % 2 == 1) == on then return end
			self:setState(function() self.phase += 1 end)
		end
		local body = w.TweenAnimationBuilder({
			tween = animation.Tween({begin = 0, ["end"] = self.phase}),
			duration = if self.phase % 2 == 1 then DOWN else UP,
			builder = function(_: w.BuildContext, value: number, child: w.Widget?): w.Widget
				return w.Transform.scale({scale = 1 - depth * pressed(value), child = child})
			end,
			child = props.child,
		})
		return w.Semantics({button = true, enabled = onTap ~= nil, selected = props.selected, label = props.label,
			child = w.GestureDetector({behavior = r.HitTestBehavior.opaque,
				onTapDown = if onTap then function(_: unknown) press(true) end else nil,
				onTapUp = if onTap then function(_: unknown) press(false) end else nil,
				onTapCancel = if onTap then function() press(false) end else nil,
				onTap = onTap,
				child = body})})
	end,
})
