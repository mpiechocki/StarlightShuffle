--!strict
--@client
-- Names floating over the lobby's tap targets ("Join mini-games" over the
-- arcade doorway, "Leaderboard" over the board), following them on screen as the
-- camera moves. `Labels.update` projects them each frame from the root;
-- the widget redraws only when a label moved by a pixel or more.
local engine = require("@moonbase/engine")
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local material = require("@icons/material")
local Style = require("./Style")

type Target = { id: string, text: string, icon: material.IconRef, lift: number, gold: boolean }
local TARGETS: {Target} = {
	{ id = "start-label", text = "Join mini-games", icon = material.play_arrow_rounded, lift = 0, gold = true },
	{ id = "leaderboard-label", text = "Leaderboard", icon = material.leaderboard_rounded, lift = 0, gold = false },
}

type Shown = { x: number, y: number, target: Target }
type Fields = { shown: {Shown}, listeners: {() -> ()} }
local Labels = {}
Labels.__index = Labels
export type Labels = typeof(setmetatable({} :: Fields, Labels))

function Labels.new(): Labels
	return setmetatable({ shown = {}, listeners = {} } :: Fields, Labels)
end

-- Projects the labels in [scene] (none when nil or it has no such buttons).
function Labels.update(self: Labels, scene: engine.Scene?)
	local shown: {Shown} = {}
	local camera = if scene and scene.isValid then scene.activeCamera else nil
	local viewport = if scene and scene.isValid then scene.viewport else nil
	if scene and camera and viewport then
		for _, target in TARGETS do
			local entity = scene:getEntity(target.id)
			if entity and entity.isValid then
				local at = entity.transform.worldPosition + vector.create(0, target.lift, 0)
				local projected = camera:worldToScreen({point = at, viewport = viewport})
				if projected and projected.inFront and projected.insideFrustum then
					table.insert(shown, { x = projected.x, y = projected.y, target = target })
				end
			end
		end
	end
	local moved = #shown ~= #self.shown
	for i, label in shown do
		local before = self.shown[i]
		if moved or before.target ~= label.target or math.abs(before.x - label.x) >= 1 or math.abs(before.y - label.y) >= 1 then
			moved = true
			break
		end
	end
	if not moved then return end
	self.shown = shown
	for _, listener in table.clone(self.listeners) do listener() end
end

type Props = { read labels: Labels }
type State = w.State<Props, { listener: (() -> ())? }>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, { listener: (() -> ())? }>

local function label(shown: Shown): w.Widget
	local target = shown.target
	local tint = if target.gold then Style.GOLD else Style.SKY
	return w.Positioned({key = w.ValueKey({value = target.id}), left = shown.x - 100, top = shown.y - 20, width = 200, height = 40,
		child = w.Center({child = w.Container({
			padding = p.EdgeInsets.symmetric({horizontal = 12, vertical = 6}),
			decoration = p.BoxDecoration({color = Style.SURFACE, borderRadius = p.BorderRadius.circular(999),
				border = p.Border.all({color = tint, width = 1.5})}),
			child = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
				w.Icon({icon = target.icon, size = 16, color = tint}),
				w.SizedBox({width = 6}),
				Style.text(target.text, Style.style(14, Style.WHITE, ui.FontWeight.w800)),
			}}),
		})}),
	})
end

Labels.View = define("WallLabels", {
	createState = function() return { listener = nil } end,
	initState = function(self: State)
		local listener = function()
			if self.mounted then self:setState(function() end) end
		end
		self.listener = listener
		table.insert(self.widget.labels.listeners, listener)
	end,
	dispose = function(self: State)
		local listeners = self.widget.labels.listeners
		local at = if self.listener then table.find(listeners, self.listener) else nil
		if at then table.remove(listeners, at) end
	end,
	build = function(self: State, _context: w.BuildContext): w.Widget
		local children: {w.Widget} = {}
		for _, shown in self.widget.labels.shown do table.insert(children, label(shown)) end
		return w.IgnorePointer({child = w.Stack({clipBehavior = ui.Clip.none, children = children})})
	end,
})

return Labels
