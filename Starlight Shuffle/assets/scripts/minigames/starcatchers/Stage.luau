--!strict
--@client
-- Starcatchers' screen, one portrait game surface sized from its container.
-- The galaxy fills it. You stand on the centre moon, largest and closest, with
-- your two lineup neighbours at the edges and up to six more of the lineup
-- small, faint and blurred in the distance (farthest first). Only YOUR stars
-- and satellites drift across the upper sky; everyone else shows their own
-- net, thrown and caught in their own session.
--
-- During play the only words are the point gains of your own catches: a small
-- pill with your points and a ring for the round, three streak lights, and
-- the scene. Before play the instruction card, then 3, 2, 1; after it the
-- shared podium. A press anywhere throws; lifting recalls (Client).
--
-- Positions follow the reference renderer: normalized net heights and offsets
-- become pixels per view, scaled for the distant tiers.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local foundation = require("@flutter/foundation")
local gestures = require("@flutter/gestures")
local services = require("@flutter/services")
local game = require("@moonbase/game")
local fonts = require("@fonts/app")
local Rules = require("./Rules")
local Assets = require("./Assets")
local Art = require("./Art")
local AvatarImage = require("../../widgets/AvatarImage")
local GameUi = require("../../widgets/GameUi")

local C = Rules.CONFIG

local function color(v: number): ui.Color return ui.Color({value = v}) end

export type Shown = { net: Rules.Net, version: number, stream: number, height: number, x: number }
export type Effect = { player: number, kind: Rules.EventKind, at: number, height: number, item: Rules.Item?, delta: number? }
export type Model = {
	frame: foundation.ChangeNotifier,
	changed: foundation.ChangeNotifier,
	ready: boolean,
	seed: number, startsAt: number,
	lineup: {number},
	participants: {[number]: Rules.Participant},
	me: number?, -- our account id when we compete
	center: number?, -- who stands in the middle: us, or the first in the lineup when watching
	-- The nets shown, by account id: ours as predicted here, the others as the
	-- server last said and moved on since; `height` and `x` are smoothed for drawing.
	shown: {[number]: Shown},
	score: number, streak: number, -- ours, as the server says
	effects: {Effect},
	standings: {Rules.Standing}?,
	reduced: boolean,
	round: () -> any,
	nextIn: () -> number,
	now: (Model) -> number,
	-- A finger (or Space, pointer -1) goes down anywhere, or lifts.
	press: (Model, pointer: number) -> (),
	release: (Model, pointer: number, cancelled: boolean) -> (),
}

type View = { player: number, x: number, side: boolean, distant: boolean, depth: number, size: number }
type Geom = { x: number, height: number, base: number, handY: number, homeY: number, size: number }

local TIER_SIZE = { 0.63, 0.44, 0.30 }
local TIER_ALPHA = { 0.36, 0.25, 0.16 }
local TIER_BLUR = { 1.1, 1.6, 2.0 }
local TIER_BASE = { 0.72, 0.635, 0.575 }
local TIER_X = { 0.15, 0.29, 0.40 }

local function views(model: Model): ({View}, {View})
	local near: {View} = {}
	local far: {View} = {}
	local center = model.center
	if not center then return near, far end
	table.insert(near, { player = center, x = 0.5, side = false, distant = false, depth = 0, size = 1 })
	local left, right = Rules.neighbours(model.lineup, center)
	if left then table.insert(near, { player = left, x = 0.075, side = true, distant = false, depth = 0, size = 1 }) end
	if right then table.insert(near, { player = right, x = 0.925, side = true, distant = false, depth = 0, size = 1 }) end
	for _, d in Rules.distant(model.lineup, center) do
		local x = TIER_X[d.depth]
		table.insert(far, { player = d.player, x = if d.offset < 0 then x else 1 - x, side = true, distant = true, depth = d.depth,
			size = TIER_SIZE[d.depth] })
	end
	table.sort(far, function(a: View, b: View): boolean
		if a.depth ~= b.depth then return a.depth > b.depth end
		return a.player < b.player
	end)
	return near, far
end

local function geom(v: View, W: number, H: number): Geom
	local height = math.min(if v.side then 205 else 244, H * (if v.side then 0.224 else 0.263)) * v.size
	local base = H * (if v.distant then TIER_BASE[v.depth] elseif v.side then 0.815 else 0.90)
	local handY = base - height * 0.48
	return { x = v.x * W, height = height, base = base, handY = handY, homeY = handY - 24 * v.size, size = v.size }
end

local function catchY(g: Geom, H: number, height: number): number
	return g.homeY - H * 0.60 * height * g.size
end

local function reach(v: View, W: number): number
	return W * (if v.side then 0.16 else 0.46) * v.size
end

-- The net's point on screen for [v].
local function netPoint(v: View, g: Geom, s: Shown, W: number, H: number): (number, number)
	local restX = g.x + g.height * 0.15 + 14 * v.size
	local x = g.x + (restX - g.x) * math.max(0, 1 - s.height * 9) + s.x * reach(v, W)
	return x, catchY(g, H, s.height)
end

local function bob(model: Model, v: View): number
	if model.reduced then return 0 end
	return math.sin(game.clock() / 1.6 + (if v.side then 1 else 0)) * 2
end

local function scaleOf(W: number): number return math.clamp(W / 390, 0.85, 1.25) end

-- A per-frame layer, rebuilt every frame from the model.
type FrameProps = { read model: Model }
type FrameFields = { listener: (() -> ())? }
type FrameState = w.State<FrameProps, FrameFields>
local defineFrame = w.StatefulWidget.define :: w.StatefulWidgetFactory<FrameProps, FrameFields>
local function frameWidget(name: string, build: (model: Model, context: w.BuildContext) -> w.Widget)
	return defineFrame(name, {
		createState = function(): FrameFields return { listener = nil } end,
		initState = function(self: FrameState)
			local listener = function() if self.mounted then self:setState(function() end) end end
			self.listener = listener
			self.widget.model.frame:addListener(listener)
		end,
		dispose = function(self: FrameState)
			if self.listener then self.widget.model.frame:removeListener(self.listener) end
		end,
		build = function(self: FrameState, context: w.BuildContext): w.Widget
			return build(self.widget.model, context)
		end,
	})
end

local function painter(onPaint: (canvas: ui.Canvas, size: ui.Size) -> ()): w.Widget
	return w.Positioned({left = 0, top = 0, right = 0, bottom = 0, child = w.IgnorePointer({child = w.CustomPaint({
		painter = w.CallbackPainter({onPaint = onPaint})})})})
end

local function elapsedOf(model: Model): number return model:now() - model.startsAt end

local function playing(model: Model): boolean
	local e = elapsedOf(model)
	return model.ready and not model.standings and e >= 0 and e < C.DURATION
end

-- The faint twinkles and the distant platforms (under the distant avatars).
local function paintBack(model: Model, canvas: ui.Canvas, W: number, H: number)
	local t = game.clock()
	for i = 1, 18 do
		local a = if model.reduced then 0.14 else 0.07 + (math.sin(t / 1.7 + i) + 1) * 0.06
		local x, y = Rules.random(7, 1, i, 1) * W, Rules.random(7, 1, i, 2) * H * 0.77
		canvas:drawRect(ui.Rect.fromLTWH(math.floor(x), math.floor(y), 1, 1), Art.paint(if i % 3 == 0 then 0xeddbba else 0xe7d9ef, a))
	end
	local _, far = views(model)
	for _, v in far do
		if model.participants[v.player] then
			local g = geom(v, W, H)
			Art.platform(canvas, g.x, g.base + 3 + bob(model, v), W * 0.235 * v.size, 20 * v.size, false, TIER_ALPHA[v.depth])
		end
	end
end

-- A net in flight spins; at rest its handle sits at the hand.
local function spin(model: Model, net: Rules.Net, elapsed: number): number
	if model.reduced or (net.stage ~= "rising" and net.stage ~= "reeling") then return 0.55 end
	return 0.55 + (elapsed - net.launchAt) * 8
end

type Point = { x: number, y: number, t: number }
local trails: {[number]: {Point}} = {}

local function drawNet(model: Model, canvas: ui.Canvas, v: View, W: number, H: number, alpha: number, elapsed: number)
	local s = model.shown[v.player]
	if not s then return end
	local g = geom(v, W, H)
	local x, y = netPoint(v, g, s, W, H)
	y += bob(model, v)
	local net = s.net
	local carrying = net.carried ~= nil
	local turn = spin(model, net, elapsed)
	local flying = net.stage == "rising" or net.stage == "reeling"
	local clock = game.clock()
	if flying and not model.reduced and not v.distant then
		local trail: {Point} = trails[v.player] or {}
		table.insert(trail, { x = x, y = y, t = clock })
		while #trail > 0 and clock - trail[1].t > 0.145 do table.remove(trail, 1) end
		trails[v.player] = trail
		for j = 2, #trail do
			canvas:drawLine(ui.Offset({dx = trail[j - 1].x, dy = trail[j - 1].y}), ui.Offset({dx = trail[j].x, dy = trail[j].y}),
				Art.stroke(if carrying then 0xf5d4a0 else 0xd6b9e7, (if v.side then 0.2 else 0.38) * j / #trail * alpha, 1 + j / #trail))
		end
	else
		trails[v.player] = nil
	end
	local sc = scaleOf(W)
	Art.net(canvas, x, y, (if v.side then 10 else 14) * v.size * sc, turn, carrying, net.stage == "tangled", alpha)
	local item = net.carried
	if item then
		local size = (if v.side then 5 elseif item.kind == "constellation" then 10 else 8) * v.size * sc
		Art.target(canvas, item.kind, x + math.sin(turn) * 5 * v.size, y - math.cos(turn) * 5 * v.size, size, alpha, clock)
	end
	-- Streak stars circle the near players.
	if not v.distant and net.streak > 0 then
		local n = math.min(4, net.streak)
		for j = 0, n - 1 do
			local a = clock / 1.6 + j * 2 * math.pi / n
			Art.star(canvas, g.x + math.cos(a) * g.height * 0.31, g.base - g.height * 0.75 + math.sin(a) * g.height * 0.09,
				3 + math.min(2, net.streak / 3), 0xf4d6a8, 0.9 * alpha)
		end
	end
	if not v.side then Art.marker(canvas, g.x, g.base - g.height - 17) end
end

local function paintDistantNets(model: Model, canvas: ui.Canvas, W: number, H: number)
	local elapsed = elapsedOf(model)
	local _, far = views(model)
	for _, v in far do drawNet(model, canvas, v, W, H, TIER_ALPHA[v.depth] * 1.6, elapsed) end
end

-- The near platforms and, during play, your own stars and satellites.
local function paintField(model: Model, canvas: ui.Canvas, W: number, H: number)
	local near = views(model)
	for _, v in near do
		if model.participants[v.player] then
			local g = geom(v, W, H)
			Art.platform(canvas, g.x, g.base + 3 + bob(model, v), W * (if v.side then 0.235 else 0.36), if v.side then 20 else 28,
				not v.side and v.player == model.me)
		end
	end
	local center = model.center
	local pt = if center then model.participants[center] else nil
	local s = if center then model.shown[center] else nil
	if not playing(model) or not pt or not s then return end
	local v = near[1]
	local g = geom(v, W, H)
	local elapsed = elapsedOf(model)
	local stars, satellites = Rules.field(model.seed, pt.stream, elapsed)
	local sc = scaleOf(W)
	local clock = game.clock()
	local flying = s.net.stage == "rising" or s.net.stage == "reeling"
	for _, d in stars do
		if not s.net.consumed[d.id] then
			local x = Rules.x(d, elapsed)
			local px, py = g.x + x * reach(v, W), catchY(g, H, d.height)
			local a = math.min(1, (C.VISIBLE - math.abs(x)) * 5)
			canvas:drawLine(ui.Offset({dx = px - d.direction * 10, dy = py}), ui.Offset({dx = px - d.direction * 22, dy = py}),
				Art.stroke(if d.kind == "star" then 0xdfc7ef else 0xf2c990, 0.2 * a, 2))
			Art.target(canvas, d.kind, px, py, (if d.kind == "constellation" then 24 elseif d.kind == "gold" then 19 else 14) * sc, a, clock)
		end
	end
	for _, d in satellites do
		local x = Rules.x(d, elapsed)
		local warn = flying and math.abs(s.height - d.height) < 0.13 and math.abs(x) < 0.5
		Art.satellite(canvas, g.x + x * reach(v, W), catchY(g, H, d.height), 17 * sc, clock, warn, math.min(1, (C.VISIBLE - math.abs(x)) * 5))
	end
end

-- The near nets and the small effects of catches, banks and hits.
local function paintNear(model: Model, canvas: ui.Canvas, W: number, H: number)
	local elapsed = elapsedOf(model)
	local near = views(model)
	for _, v in near do
		if model.participants[v.player] then drawNet(model, canvas, v, W, H, if v.side then 0.85 else 1, elapsed) end
	end
	local clock = game.clock()
	for _, e in model.effects do
		local progress = (clock - e.at) / 1
		local v: View? = nil
		for _, nv in near do if nv.player == e.player then v = nv end end
		if v and progress >= 0 and progress < 1 then
			local g = geom(v, W, H)
			local y = catchY(g, H, e.height)
			local fade = 1 - progress
			if e.kind == "bank" then
				for j = 0, 5 do
					Art.star(canvas, g.x + math.cos(j * 2.4) * progress * 40, y + math.sin(j * 2.4) * progress * 28, 2 * fade + 0.5, 0xffdf9f, fade)
				end
			elseif e.kind == "snap" then
				local line = Art.stroke(0xe8a9bf, fade, 2)
				canvas:drawLine(ui.Offset({dx = g.x - 10 - progress * 20, dy = y - 8}), ui.Offset({dx = g.x + 6, dy = y + 5}), line)
				canvas:drawLine(ui.Offset({dx = g.x + 10 + progress * 20, dy = y - 8}), ui.Offset({dx = g.x - 6, dy = y + 5}), line)
				if e.item then Art.target(canvas, e.item.kind, g.x + progress * 45, y + progress * 95, 12 * fade + 1, fade, clock) end
			elseif v.player == model.center then
				canvas:drawCircle(ui.Offset({dx = g.x, dy = y}), 12 + progress * 25, Art.stroke(0xfff0c0, fade, 1))
			end
		end
	end
end

-- Everyone's avatar: the distant ones faint and blurred, the neighbours a
-- touch faded, you in front; a tangled net shakes its player a little.
local function avatars(model: Model, list: {View}, W: number, H: number): {w.Widget}
	local out: {w.Widget} = {}
	for _, v in list do
		local pt = model.participants[v.player]
		if pt then
			local g = geom(v, W, H)
			local width = g.height * 0.62
			local s = model.shown[v.player]
			local shake = if s and s.net.stage == "tangled" and not model.reduced then math.sin(game.clock() * 80) * 2 else 0
			local body: w.Widget = AvatarImage.body(pt.outfit, width, g.height)
			if v.distant then
				local sigma = if model.reduced then 0 else TIER_BLUR[v.depth]
				body = w.Opacity({opacity = TIER_ALPHA[v.depth] * 1.6, child = if sigma > 0
					then w.ImageFiltered({imageFilter = ui.ImageFilter.blur({sigmaX = sigma, sigmaY = sigma}), child = body}) else body})
			elseif v.side then
				body = w.Opacity({opacity = 0.85, child = body})
			end
			table.insert(out, w.Positioned({key = w.ValueKey({value = "avatar" .. v.player}), left = g.x - width / 2 + shake,
				top = g.base - g.height + bob(model, v), width = width, height = g.height, child = w.IgnorePointer({child = body})}))
		end
	end
	return out
end

local Scene = frameWidget("StarcatchersScene", function(model: Model, _context: w.BuildContext): w.Widget
	return w.LayoutBuilder({builder = function(_: w.BuildContext, constraints: r.BoxConstraints): w.Widget
		local W, H = constraints.maxWidth, constraints.maxHeight
		local near, far = views(model)
		local layers: {w.Widget} = {
			painter(function(canvas: ui.Canvas, _: ui.Size) paintBack(model, canvas, W, H) end),
		}
		for _, a in avatars(model, far, W, H) do table.insert(layers, a) end
		table.insert(layers, painter(function(canvas: ui.Canvas, _: ui.Size) paintDistantNets(model, canvas, W, H) end))
		table.insert(layers, painter(function(canvas: ui.Canvas, _: ui.Size) paintField(model, canvas, W, H) end))
		-- Neighbours behind you.
		local ordered: {View} = {}
		for i = #near, 1, -1 do table.insert(ordered, near[i]) end
		for _, a in avatars(model, ordered, W, H) do table.insert(layers, a) end
		table.insert(layers, painter(function(canvas: ui.Canvas, _: ui.Size) paintNear(model, canvas, W, H) end))
		-- Your own point gains, as numbers.
		local clock = game.clock()
		for i, e in model.effects do
			local progress = clock - e.at
			if e.kind == "bank" and e.player == model.me and e.delta and progress >= 0 and progress < 1 and near[1] then
				local g = geom(near[1], W, H)
				table.insert(layers, w.Positioned({key = w.ValueKey({value = "gain" .. i .. ":" .. e.at}), left = g.x - 60, width = 120,
					top = catchY(g, H, 0) - 50 - progress * 35, child = w.IgnorePointer({child = w.Opacity({opacity = 1 - progress,
						child = w.Text({data = "+" .. e.delta, textAlign = ui.TextAlign.center, style = p.TextStyle({fontFamily = fonts.lato,
							fontSize = 27, fontWeight = ui.FontWeight.w800, color = color(0xffffe7b5),
							shadows = {ui.Shadow({color = color(0xff4c3a62), blurRadius = 3, offset = ui.Offset({dx = 0, dy = 1})})}})})})})}))
			end
		end
		return w.Stack({clipBehavior = ui.Clip.hardEdge, children = layers})
	end})
end)

-- The top, under the cycle's head (whose timer is the time left): your
-- points and three streak lights.
local Top = frameWidget("StarcatchersTop", function(model: Model, _context: w.BuildContext): w.Widget
	if not model.ready or not model.me or model.standings then return w.SizedBox.shrink({}) end
	local e = elapsedOf(model)
	local lights: {w.Widget} = {}
	for i = 1, 3 do
		local on = e >= 0 and i <= math.min(3, model.streak)
		table.insert(lights, w.Container({width = 5, height = 5, margin = p.EdgeInsets.symmetric({horizontal = 2.5}),
			decoration = p.BoxDecoration({shape = p.BoxShape.circle, color = color(if on then 0xfff4d698 else 0x3db7a0c8),
				boxShadow = if on then {p.BoxShadow({color = color(0x88ffda9b), blurRadius = 7})} else nil})}))
	end
	return w.IgnorePointer({child = w.Align({alignment = p.Alignment.topCenter, child = w.Padding({padding = p.EdgeInsets.only({top = GameUi.HEAD}),
		child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
			GameUi.hud(w.Row({mainAxisSize = w.MainAxisSize.min, children = {
				w.SizedBox({width = 24, height = 24, child = w.CustomPaint({painter = w.CallbackPainter({onPaint = function(canvas: ui.Canvas, size: ui.Size)
					Art.star(canvas, size.width / 2, size.height / 2 + 1, size.width * 0.5, 0xffe6ab)
				end})})}),
				w.SizedBox({width = 8}),
				w.Text({data = tostring(model.score), style = GameUi.style(26, GameUi.TEXT, ui.FontWeight.w800, -1)}),
			}}), p.EdgeInsets.symmetric({horizontal = 14, vertical = 8})),
			w.SizedBox({height = 8}),
			w.Row({mainAxisSize = w.MainAxisSize.min, children = lights}),
		}})})})})
end)

local function legend(kind: Rules.Kind, label: string): w.Widget
	return w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 10}), child = w.Column({children = {
		-- On a bit of night sky, as they appear in play.
		w.Container({width = 40, height = 40, decoration = p.BoxDecoration({color = color(0xff3a3157), shape = p.BoxShape.circle}),
			child = w.CustomPaint({painter = w.CallbackPainter({onPaint = function(canvas: ui.Canvas, size: ui.Size)
				Art.target(canvas, kind, size.width / 2, size.height / 2, if kind == "constellation" then 13 elseif kind == "gold" then 11 else 9)
			end})})}),
		w.SizedBox({height = 4}),
		w.Text({data = label, style = GameUi.style(13, GameUi.CARD_TEXT, ui.FontWeight.w800)}),
	}})})
end

-- Before play: the card, then the large 3, 2, 1.
local Prep = frameWidget("StarcatchersPrep", function(model: Model, _context: w.BuildContext): w.Widget
	if not model.ready or model.standings then return w.SizedBox.shrink({}) end
	local left = -elapsedOf(model)
	if left <= 0 then return w.SizedBox.shrink({}) end
	if left <= C.FINAL_COUNT then return GameUi.countdown(math.max(1, math.ceil(left))) end
	if not model.me then
		return w.IgnorePointer({child = GameUi.instructionCard({
			GameUi.instruction("This round started without you.", true),
			w.SizedBox({height = 6}),
			GameUi.instruction("Watch, then play the next one."),
		})})
	end
	return w.IgnorePointer({child = GameUi.instructionCard({
		GameUi.instruction("Hold to throw. Release to recall.", true),
		w.SizedBox({height = 6}),
		GameUi.instruction("Choose your stars. Avoid satellites."),
		w.SizedBox({height = 14}),
		w.Row({mainAxisAlignment = w.MainAxisAlignment.center, children = {
			legend("star", "+1"), legend("gold", "+3"), legend("constellation", "+5"),
		}}),
		w.SizedBox({height = 12}),
		w.Text({data = "Starts automatically", style = GameUi.style(11, GameUi.CARD_MUTED, ui.FontWeight.w800, 1)}),
	})})
end)

local function results(model: Model): w.Widget?
	local standings = model.standings
	local round = model.round()
	if not standings or not round or round.phase ~= "results" then return nil end
	local mine: Rules.Standing? = nil
	for _, s in standings do if s.player == model.me then mine = s end end
	local rows: {GameUi.PodiumRow} = {}
	for _, s in standings do
		local pt = model.participants[s.player]
		table.insert(rows, { place = s.place, name = s.name, outfit = if pt then pt.outfit else nil, points = s.score, mine = s.player == model.me })
	end
	return GameUi.podium({
		overline = "THAT'S AN ORBIT",
		heading = if mine and mine.place == 1 then "First place, starlight!" else "Written in the stars.",
		summary = if mine then "You caught " .. mine.score .. (if mine.score == 1 then " point" else " points") .. " of starlight."
			else "You watched this round.",
		rows = rows,
		footer = "Back to the lobby in " .. math.max(0, math.ceil(model.nextIn())) .. "s",
	})
end

type Props = { read model: Model }
type Fields = { listener: (() -> ())?, unlisten: (() -> ())?, focus: w.FocusNode?, spaceDown: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local Stage = {}

-- Forget drawing state between rounds (trails).
function Stage.reset()
	table.clear(trails)
end

Stage.View = define("StarcatchersStage", {
	createState = function(): Fields return { listener = nil, unlisten = nil, focus = nil, spaceDown = false } end,
	initState = function(self: State)
		local model = self.widget.model
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		model.changed:addListener(listener)
		self.unlisten = Assets.listen(listener)
		self.focus = w.FocusNode({debugLabel = "starcatchers"})
	end,
	dispose = function(self: State)
		if self.listener then self.widget.model.changed:removeListener(self.listener) end
		if self.unlisten then self.unlisten() end
		if self.focus then self.focus:dispose() end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local model = self.widget.model
		model.reduced = w.MediaQuery.disableAnimationsOf(context)
		local galaxy = Assets.get().galaxy
		local layers: {w.Widget} = { w.Container({color = color(0xff282344)}) }
		if galaxy and galaxy.isValid then
			table.insert(layers, w.Image({image = game.image(galaxy), fit = p.BoxFit.cover, alignment = p.Alignment({x = 0.36, y = 0}),
				filterQuality = ui.FilterQuality.none}))
		end
		if model.ready then
			table.insert(layers, Scene({model = model}))
			table.insert(layers, w.SafeArea({child = Top({model = model})}))
			table.insert(layers, Prep({model = model}))
		end
		local wrap = results(model)
		if wrap then table.insert(layers, wrap) end
		-- A press anywhere throws, lifting recalls; Space does the same.
		return w.Focus({focusNode = self.focus, autofocus = true,
			onKeyEvent = function(_node: w.FocusNode, event: services.KeyEvent): w.KeyEventResult
				local space = services.LogicalKeyboardKey.space
				if event.logicalKey.keyId ~= space.keyId then return w.KeyEventResult.ignored end
				local down = services.HardwareKeyboard.getInstance():isLogicalKeyPressed(space)
				if down and not self.spaceDown then model:press(-1) elseif not down and self.spaceDown then model:release(-1, false) end
				self.spaceDown = down
				return w.KeyEventResult.handled
			end,
			child = w.Semantics({label = "Starcatchers. Hold to throw your net, release to recall it.", child = w.Listener({
				behavior = r.HitTestBehavior.opaque,
				onPointerDown = function(event: gestures.PointerDownEvent) model:press(event.pointer) end,
				onPointerUp = function(event: gestures.PointerUpEvent) model:release(event.pointer, false) end,
				onPointerCancel = function(event: gestures.PointerCancelEvent) model:release(event.pointer, true) end,
				child = w.Stack({fit = w.StackFit.expand, children = layers})})})})
	end,
})

return table.freeze(Stage)
