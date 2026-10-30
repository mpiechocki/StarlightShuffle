--!strict
--@client
-- Pointer input and the on-screen joystick over the game view. Adapted from the
-- runway project's GameControls (same gestures), without its theme or labels,
-- by way of Sky Lounge.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local gestures = require("@flutter/gestures")
local game = require("@moonbase/game")
local Controls = require("../gameplay/Controls")

local function color(value: number): ui.Color return ui.Color({value = value}) end
local JOYSTICK_FILL = color(0x22ffffff)
local JOYSTICK_BORDER = color(0x99ffffff)
local JOYSTICK_THUMB = color(0xccb0a8ea)

type Props = { read controls: Controls.Controller }
type Fields = { changed: (() -> ())? }
type State = w.State<Props, Fields>
local defineJoystick = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>
local Joystick = defineJoystick("Joystick", {
	createState = function(): Fields return { changed = nil } end,
	initState = function(self: State)
		local changed = function()
			if self.mounted then self:setState(function() end) end
		end
		self.changed = changed
		self.widget.controls.onJoystickChanged = changed
	end,
	dispose = function(self: State)
		if self.widget.controls.onJoystickChanged == self.changed then
			self.widget.controls.onJoystickChanged = nil
		end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		local stick = self.widget.controls.joystick
		if not stick then return w.SizedBox.shrink({}) end
		return w.Stack({ clipBehavior = ui.Clip.none, children = {
			w.Positioned({ left = stick.x - 56, top = stick.y - 56, child = w.Container({
				width = 112, height = 112,
				decoration = p.BoxDecoration({ color = JOYSTICK_FILL, shape = p.BoxShape.circle,
					border = p.Border.all({ color = JOYSTICK_BORDER, width = 1.5 }) }),
			}) }),
			w.Positioned({ left = stick.x + stick.dx - 22, top = stick.y + stick.dy - 22, child = w.Container({
				width = 44, height = 44,
				decoration = p.BoxDecoration({ color = JOYSTICK_THUMB, shape = p.BoxShape.circle }),
			}) }),
		} })
	end,
})

return function(controls: Controls.Controller): w.Widget
	return w.LayoutBuilder({ builder = function(context: w.BuildContext, constraints: r.BoxConstraints): w.Widget
		controls:resize(constraints.maxWidth, constraints.maxHeight)
		-- The camera looks past the on-screen keyboard.
		controls:setObscured(w.MediaQuery.viewInsetsOf(context).bottom)
		return w.Listener({
			behavior = r.HitTestBehavior.opaque,
			onPointerDown = function(event: gestures.PointerDownEvent)
				controls:pointerDown(event.pointer, event.localPosition.dx, event.localPosition.dy, bit32.band(event.buttons, 2) ~= 0)
			end,
			onPointerMove = function(event: gestures.PointerMoveEvent)
				controls:pointerMove(event.pointer, event.localPosition.dx, event.localPosition.dy)
			end,
			onPointerUp = function(event: gestures.PointerUpEvent) controls:pointerUp(event.pointer, false) end,
			onPointerCancel = function(event: gestures.PointerCancelEvent) controls:pointerUp(event.pointer, true) end,
			onPointerSignal = function(event: gestures.PointerSignalEvent)
				-- Flutter also sends non-scroll signals; only scroll events expose this getter.
				local ok, dy = pcall(function(): number return (event :: gestures.PointerScrollEvent).scrollDelta.dy end)
				if ok then controls:scroll(dy) end
			end,
			onPointerPanZoomStart = function(_: gestures.PointerPanZoomStartEvent) controls:trackpadStart() end,
			onPointerPanZoomUpdate = function(event: gestures.PointerPanZoomUpdateEvent) controls:trackpadUpdate(event.scale, event.pan.dx) end,
			onPointerPanZoomEnd = function(_: gestures.PointerPanZoomEndEvent) controls:trackpadEnd() end,
			child = w.Stack({ fit = w.StackFit.expand, children = {
				game.GameView({}),
				w.IgnorePointer({ child = w.RepaintBoundary({ child = Joystick({ controls = controls }) }) }),
			} }),
		})
	end })
end
