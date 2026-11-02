--!strict
--@client
-- Blast Mining's screen: one portrait game surface over the whole view. The
-- cave backdrop fills it; the local miner stands centred, larger and nearer,
-- on a bright halo with a white marker above and the clearest strike circle;
-- up to two rivals stand smaller and farther back at the edges, chosen in
-- stream order (the next and previous connected miners after ours) so they do
-- not swap as scores change. Each miner's items fall into their own strike
-- circle; pickaxes, chips and explosions are painted over the avatars, and
-- the +1/+3/-3 labels rise from the impacts.
--
-- Before play: the instruction, the three items with their points and a
-- 3-2-1 count. During play: only the score pill with its progress ring, and
-- the game itself. After: the results card. Any tap or Space swings, except
-- on the cycle's own buttons, which take their taps.
--
-- Painters and their paths are made once; the moving parts repaint or rebuild
-- every frame from the model's clocks, so motion does not depend on frame rate.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local services = require("@flutter/services")
local foundation = require("@flutter/foundation")
local gestures = require("@flutter/gestures")
local game = require("@moonbase/game")
local fonts = require("@fonts/app")
local Rules = require("./Rules")
local Art = require("./Art")
local Assets = require("./Assets")
local AvatarImage = require("../../widgets/AvatarImage")
local PlayerTag = require("../../widgets/PlayerTag")
local GameUi = require("../../widgets/GameUi")

local C = Rules.CONFIG

export type Effect = { stream: number, kind: Rules.Kind, delta: number, at: number, item: number, x: number?, seed: number }
export type Model = {
	frame: foundation.ChangeNotifier, -- every frame
	changed: foundation.ChangeNotifier, -- when what is shown changes otherwise
	ready: boolean, -- a snapshot came
	startsAt: number, endsAt: number, over: boolean,
	miners: {[number]: Rules.Miner}, -- by stream
	me: number?, -- our stream; nil when watching
	items: {[number]: Rules.Item},
	hit: {[number]: boolean}, -- confirmed
	guessed: {[number]: number}, -- item id -> swing sequence that shattered it early
	swings: {[number]: { at: number, length: number }}, -- by stream, game.clock()
	shakes: {[number]: number}, -- by stream, game.clock() it started
	effects: {Effect},
	ripples: {number}, -- our swings, game.clock()
	standings: {Rules.Standing}?,
	reduced: boolean, haptics: boolean,
	round: () -> any,
	nextIn: () -> number,
	now: (Model) -> number,
	tap: (Model) -> (),
}

local function color(v: number): ui.Color return ui.Color({value = v}) end

-- Where a miner stands: centre (ours) or a side, sized to the view.
type Slot = { stream: number, x: number, side: boolean, height: number, base: number, line: number }

local function slot(stream: number, where: "left" | "centre" | "right", width: number, height: number): Slot
	local side = where ~= "centre"
	local tall = math.min(height * (if side then 0.236 else 0.285), if side then 218 else 268)
	local base = height * (if side then 0.824 else 0.908)
	local x = if where == "left" then width * 0.085 elseif where == "right" then width * 0.915 else width * 0.5
	return { stream = stream, x = x, side = side, height = tall, base = base, line = base - tall * 1.1 }
end

-- The miners shown: ours in the centre, and the next and previous connected
-- miners in stream order at the sides (when there are any).
local function slots(model: Model, width: number, height: number): {Slot}
	local streams: {number} = {}
	for stream, miner in model.miners do
		if miner.connected or stream == model.me then table.insert(streams, stream) end
	end
	table.sort(streams)
	if #streams == 0 then return {} end
	local centre = model.me or streams[1]
	local at = table.find(streams, centre)
	local out: {Slot} = {}
	if not at then return out end
	table.insert(out, slot(centre, "centre", width, height))
	local count = #streams
	if count >= 2 then table.insert(out, slot(streams[at % count + 1], "right", width, height)) end
	if count >= 3 then table.insert(out, slot(streams[(at - 2) % count + 1], "left", width, height)) end
	return out
end

-- How far into its swing a miner is (0 at rest, 1 at the top).
local function swingOf(model: Model, stream: number, clock: number): number
	local s = model.swings[stream]
	if not s then return 0 end
	local phase = math.max(0, 1 - (clock - s.at) / s.length)
	return math.sin(phase * math.pi)
end

local function shakeOf(model: Model, stream: number, clock: number): (number, number)
	local started = model.shakes[stream]
	if not started or model.reduced then return 0, 0 end
	local left = math.max(0, 1 - (clock - started) / C.SHAKE)
	if left <= 0 then return 0, 0 end
	return math.sin(clock * 120) * 3.6 * left, math.cos(clock * 140) * 1.5 * left
end

-- Behind the miners: the darker recess the items fall through, halos and strike circles.
local function paintBack(model: Model, canvas: ui.Canvas, size: ui.Size)
	local width, height = size.width, size.height
	canvas:drawRect(ui.Rect.fromLTWH(0, 0, width, height * 0.22), Art.paint(0x2a1f3a, 0.28))
	canvas:drawRect(ui.Rect.fromLTWH(0, height * 0.22, width, height * 0.22), Art.paint(0x2a1f3a, 0.14))
	canvas:drawRect(ui.Rect.fromLTWH(0, height * 0.44, width, height * 0.2), Art.paint(0x2a1f3a, 0.05))
	local clock = game.clock()
	for _, s in slots(model, width, height) do
		local halo = s.height * (if s.side then 0.3 else 0.42)
		canvas:drawOval(ui.Rect.fromCenter({center = ui.Offset({dx = s.x, dy = s.base}), width = halo * 2, height = halo * 0.55}),
			if s.side then Art.glow(0x594168, 0.18, 10) else Art.glow(0xfff5ff, 0.75, 14))
		-- The strike circle: ours bright and glowing, the rivals' faint.
		local rx, ry = if s.side then 16 else 24, if s.side then 5 else 8
		local ring = ui.Rect.fromCenter({center = ui.Offset({dx = s.x, dy = s.line}), width = rx * 2, height = ry * 2})
		if not s.side then canvas:drawOval(ring, Art.glow(0xe7c1ff, 0.55, 6)) end
		canvas:drawOval(ring, Art.stroke(0xfff0ff, if s.side then 0.28 else 0.9, if s.side then 1 else 1.6))
		if s.stream == model.me then
			for _, at in model.ripples do
				local t = (clock - at) / 0.24
				canvas:drawOval(ui.Rect.fromCenter({center = ui.Offset({dx = s.x, dy = s.line}), width = (24 + t * 23) * 2,
					height = (8 + t * 6) * 2}), Art.stroke(0xfff0ff, (1 - t) * 0.6, 1.2))
			end
		end
	end
end

local function drawItem(model: Model, canvas: ui.Canvas, item: Rules.Item, s: Slot, now: number, clock: number)
	local fall = item.strikeAt - item.spawnAt
	local progress = 1 + (now - item.strikeAt) / math.max(0.05, fall)
	if progress < 0 then return end
	local top = s.base * 0.13
	local y = top + (s.line - top) * progress
	if y > s.base - s.height * 0.36 then return end
	local x = s.x + item.drift * (1 - progress) * (if s.side then 0.7 else 1)
	local size = if s.side then 40 else 56
	local alpha = if s.side then 0.76 else math.min(1, progress * 5)
	if item.kind == "bomb" then
		canvas:drawCircle(ui.Offset({dx = x, dy = y}), size * 0.42, Art.glow(0xffdf93, 0.35 * alpha, 10))
	end
	Art.sprite(canvas, item.kind, x, y, size, item.drift * 0.015, alpha)
	if item.kind == "gem" and not model.reduced then
		-- One restrained glint.
		local glint = 0.5 + 0.5 * math.sin(clock * 25)
		canvas:drawCircle(ui.Offset({dx = x - 10, dy = y - 10}), 2.2, Art.glow(0xfff5ff, glint * alpha, 2.5))
	end
end

local function drawPickaxe(model: Model, canvas: ui.Canvas, s: Slot, clock: number)
	local swing = swingOf(model, s.stream, clock)
	local dx, dy = shakeOf(model, s.stream, clock)
	local bob = if model.reduced then 0 else swing * 2
	local lift = swing * s.height * 0.19
	local tool = s.height * 0.58
	canvas:save()
	canvas:translate(s.x + dx + s.height * (C.HAND_X - swing * 0.08), s.base + dy - s.height * C.HAND_Y - bob - lift)
	canvas:rotate(0.4 - swing * 0.7)
	Art.sprite(canvas, "pickaxe", 0, -tool * 0.38, tool, 0, if s.side then 0.75 else 1)
	if swing > 0.2 and not model.reduced then
		-- A small impact arc.
		canvas:drawArc(ui.Rect.fromCenter({center = ui.Offset({dx = 0, dy = -tool * 0.42}), width = tool * 0.68, height = tool * 0.68}),
			-2.7, 2.2, false, Art.stroke(0xf3d6ff, swing * 0.32, 2))
	end
	canvas:restore()
end

local function drawEffect(model: Model, canvas: ui.Canvas, e: Effect, s: Slot, clock: number)
	local t = (clock - e.at) / 0.65
	if t >= 1 then return end
	local x, y = s.x, s.line
	local scale = if s.side then 0.7 else 1
	if e.kind == "bomb" then
		local blast = math.min(1, t * 2.3)
		canvas:drawCircle(ui.Offset({dx = x, dy = y}), (22 + blast * 18) * scale, Art.glow(0xffc76d, (1 - t) * 0.7, 9))
		canvas:drawCircle(ui.Offset({dx = x, dy = y}), (10 + blast * 8) * scale, Art.glow(0xfff4bc, (1 - t) * 0.9, 5))
		if not model.reduced then
			canvas:drawCircle(ui.Offset({dx = x, dy = y}), (12 + t * 46) * scale, Art.stroke(0xffe9b0, (1 - t) * 0.55, 1.5))
			for k = 0, 2 do
				local a = (e.seed * 1.7 + k * 2.1)
				canvas:drawCircle(ui.Offset({dx = x + math.cos(a) * 20 * t * scale, dy = y - 6 - 22 * t * scale + math.sin(a) * 6}),
					(5 + 6 * t) * scale, Art.glow(0xb9a8c8, (1 - t) * 0.45, 4))
			end
		end
	else
		local colours = Art.CHIPS[e.kind]
		local count = if model.reduced then 3 else 6
		for k = 1, count do
			local a = e.seed * 2.39 + k * (2 * math.pi / count)
			local reach = (18 + (k % 3) * 7) * t * scale
			Art.chip(canvas, x + math.cos(a) * reach, y + math.sin(a) * reach + 30 * t * t, 3.5 * scale, a + t * 4,
				colours[(k % #colours) + 1], 1 - t)
		end
	end
end

-- Over the miners: falling items, pickaxes, effects and our marker.
local function paintFront(model: Model, canvas: ui.Canvas, size: ui.Size)
	if not model.ready then return end
	local now, clock = model:now(), game.clock()
	local shown = slots(model, size.width, size.height)
	local byStream: {[number]: Slot} = {}
	for _, s in shown do byStream[s.stream] = s end
	if now >= model.startsAt and now <= model.endsAt + 1 then
		for _, item in model.items do
			local s = byStream[item.stream]
			if s and not model.hit[item.id] and not model.guessed[item.id] and now >= item.spawnAt then
				drawItem(model, canvas, item, s, now, clock)
			end
		end
	end
	for _, s in shown do drawPickaxe(model, canvas, s, clock) end
	for _, e in model.effects do
		local s = byStream[e.stream]
		if s then drawEffect(model, canvas, e, s, clock) end
	end
	local mine = if model.me then byStream[model.me] else nil
	if mine then Art.marker(canvas, mine.x, mine.base - mine.height - 19) end
end

-- The miners' avatars and the rising point labels, for this frame.
local function miners(model: Model): w.Widget
		return w.LayoutBuilder({builder = function(_: w.BuildContext, constraints: r.BoxConstraints): w.Widget
			local width, height = constraints.maxWidth, constraints.maxHeight
			local clock = game.clock()
			local children: {w.Widget} = {}
			local shown = slots(model, width, height)
			-- Rivals first, so ours stands in front.
			table.sort(shown, function(a: Slot, b: Slot): boolean return a.side and not b.side end)
			for _, s in shown do
				local miner = model.miners[s.stream]
				local swing = swingOf(model, s.stream, clock)
				local dx, dy = shakeOf(model, s.stream, clock)
				local bob = if model.reduced then 0 else swing * 2
				local box = s.height * 0.8
				table.insert(children, w.Positioned({key = w.ValueKey({value = "miner" .. s.stream}),
					left = s.x - box / 2 + dx, top = s.base - s.height - bob + dy, width = box, height = s.height,
					child = w.Opacity({opacity = if s.side then 0.74 else 1,
						child = AvatarImage.body(if miner then miner.outfit else nil, box, s.height)})}))
				-- Their name at their feet, in their shop look (widgets/PlayerTag).
				if miner then
					table.insert(children, w.Positioned({key = w.ValueKey({value = "name" .. s.stream}),
						left = s.x - 80, width = 160, top = s.base + 2, child = w.Center({child = w.Opacity({opacity = if s.side then 0.8 else 1,
							child = PlayerTag({player = miner.player, name = miner.name, size = if s.side then 9 else 11, maxWidth = 150})})})}))
				end
			end
			for _, e in model.effects do
				local s: Slot? = nil
				for _, candidate in shown do if candidate.stream == e.stream then s = candidate end end
				local t = (clock - e.at) / 0.65
				if s and t < 1 then
					local rise = (if model.reduced then 0 else 26 * t)
					local label = if e.delta > 0 then "+" .. e.delta else "−" .. math.abs(e.delta)
					table.insert(children, w.Positioned({key = w.ValueKey({value = "fx" .. e.seed}),
						left = s.x - 40, width = 80, top = s.line - 44 - rise,
						child = w.Opacity({opacity = math.clamp(1.4 - t * 1.4, 0, 1), child = w.Text({data = label,
							textAlign = ui.TextAlign.center,
							style = p.TextStyle({fontFamily = fonts.lato, fontSize = if s.side then 16 else 22,
								fontWeight = ui.FontWeight.w900,
								color = color(if e.delta < 0 then 0xffffd27a elseif e.delta > 1 then 0xfff1dcff else 0xffffffff),
								shadows = {ui.Shadow({color = color(0xaa2a1f3a), blurRadius = 4, offset = ui.Offset({dx = 0, dy = 1})})}})})})}))
				end
			end
			return w.Stack({clipBehavior = ui.Clip.hardEdge, children = children})
		end})
end

-- An item icon for the legend, painted.
local function icon(sprite: Art.Sprite, size: number): w.Widget
	return w.CustomPaint({size = ui.Size({width = size, height = size}), painter = w.CallbackPainter({
		onPaint = function(canvas: ui.Canvas, s: ui.Size) Art.sprite(canvas, sprite, s.width / 2, s.height / 2, s.width) end,
		shouldRepaint = function() return false end})})
end

local function legend(sprite: Art.Sprite, points: string): w.Widget
	return w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 10}), child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
		icon(sprite, 40),
		w.Text({data = points, style = GameUi.style(15, GameUi.CARD_TEXT, ui.FontWeight.w900)}),
	}})})
end

-- Before play: the instruction card, then the large 3-2-1 in its place.
local function before(model: Model): w.Widget?
	local now = model:now()
	if model.ready and now >= model.startsAt then return nil end
	local left = if model.ready then model.startsAt - now else math.huge
	if left <= 3 then return GameUi.countdown(math.max(1, math.ceil(left))) end
	if model.ready and not model.me then
		return GameUi.instructionCard({
			GameUi.instruction("This round started without you.", true),
			w.SizedBox({height = 6}),
			GameUi.instruction("You'll mine in the next one."),
		})
	end
	return GameUi.instructionCard({
		GameUi.instruction("Tap anywhere to swing your pickaxe", true),
		w.SizedBox({height = 14}),
		w.Row({mainAxisSize = w.MainAxisSize.min, children = { legend("rock", "+1"), legend("gem", "+3"), legend("bomb", "−3") }}),
	})
end

-- The score pill, under the cycle's head (whose timer is the time left): a
-- small gem and our points.
local function pill(model: Model): w.Widget?
	local me = model.me
	local now = model:now()
	if not me or not model.ready or now < model.startsAt or model.over then return nil end
	local miner = model.miners[me]
	return w.Align({alignment = p.Alignment.topCenter, child = w.Padding({padding = p.EdgeInsets.only({top = GameUi.HEAD}),
		child = w.Container({
			height = 40, padding = p.EdgeInsets.symmetric({horizontal = 12}),
			decoration = p.BoxDecoration({color = GameUi.HUD, borderRadius = p.BorderRadius.circular(999),
				border = p.Border.all({color = GameUi.HUD_EDGE, width = 1})}),
			child = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
				icon("gem", 22),
				w.SizedBox({width = 6}),
				w.Text({data = tostring(if miner then miner.score else 0), style = GameUi.style(17, GameUi.TEXT, ui.FontWeight.w900)}),
			}}),
		})})})
end

local function results(model: Model): w.Widget?
	local standings = model.standings
	local round = model.round()
	if not standings or not round or round.phase ~= "results" then return nil end
	local mine: Rules.Standing? = nil
	local me = if model.me then model.miners[model.me] else nil
	for _, s in standings do if me and s.player == me.player then mine = s end end
	local outfits: {[number]: {number}?} = {}
	for _, miner in model.miners do outfits[miner.player] = miner.outfit end
	local rows: {GameUi.PodiumRow} = {}
	for _, s in standings do
		table.insert(rows, { place = s.place, name = s.name, outfit = outfits[s.player], points = s.score,
			mine = mine ~= nil and s.player == mine.player })
	end
	return GameUi.podium({
		heading = if not mine then "That's a wrap"
			elseif mine.place == 1 then "First place, lovely!"
			elseif mine.place <= 3 then "A gem of a round!"
			else "Beautifully mined.",
		summary = if mine then "You collected " .. mine.score .. (if mine.score == 1 then " point" else " points") .. " in the caverns."
			else "Here's who mined the most.",
		rows = rows,
		footer = "Back to the lobby in " .. math.max(0, math.ceil(model.nextIn())) .. "s",
	})
end

type Props = { read model: Model }
type Fields = { painters: { back: w.CallbackPainter, front: w.CallbackPainter }?, focus: w.FocusNode?,
	listener: (() -> ())?, unlisten: (() -> ())?, spaceDown: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local Stage = {}

Stage.View = define("BlastMiningStage", {
	createState = function(): Fields
		return { painters = nil, focus = nil, listener = nil, unlisten = nil, spaceDown = false }
	end,
	initState = function(self: State)
		local model = self.widget.model
		self.painters = {
			back = w.CallbackPainter({repaint = model.frame,
				onPaint = function(canvas: ui.Canvas, size: ui.Size) paintBack(model, canvas, size) end}),
			front = w.CallbackPainter({repaint = model.frame,
				onPaint = function(canvas: ui.Canvas, size: ui.Size) paintFront(model, canvas, size) end}),
		}
		self.focus = w.FocusNode({debugLabel = "blast-mining"})
		-- Rebuilt every frame (the avatars, labels, countdown and progress move)
		-- and on every change.
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		model.changed:addListener(listener)
		model.frame:addListener(listener)
		self.unlisten = Assets.listen(listener)
	end,
	dispose = function(self: State)
		local model = self.widget.model
		if self.listener then
			model.changed:removeListener(self.listener)
			model.frame:removeListener(self.listener)
		end
		if self.unlisten then self.unlisten() end
		if self.focus then self.focus:dispose() end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local model = self.widget.model
		model.reduced = w.MediaQuery.disableAnimationsOf(context)
		local painters = assert(self.painters)
		local cave = Assets.get().cave
		local layers: {w.Widget} = {
			w.Container({color = color(0xff3a2c4c)}),
		}
		if cave and cave.isValid then
			table.insert(layers, w.Image({image = game.image(cave), fit = p.BoxFit.cover, alignment = p.Alignment.center,
				filterQuality = ui.FilterQuality.none}))
		end
		table.insert(layers, w.CustomPaint({painter = painters.back}))
		table.insert(layers, miners(model))
		table.insert(layers, w.CustomPaint({painter = painters.front}))
		local top = pill(model)
		if top then table.insert(layers, w.SafeArea({child = top})) end
		local card = before(model)
		if card then table.insert(layers, card) end
		local wrap = results(model)
		-- Every touch on the surface swings (the cycle's own buttons above take theirs).
		local surface = w.Listener({behavior = r.HitTestBehavior.opaque,
			onPointerDown = function(_: gestures.PointerDownEvent) model:tap() end,
			child = w.Stack({fit = w.StackFit.expand, children = layers})})
		local stack: {w.Widget} = { surface }
		if wrap then table.insert(stack, wrap) end
		return w.Focus({focusNode = self.focus, autofocus = true,
			onKeyEvent = function(_node: w.FocusNode, event: services.KeyEvent): w.KeyEventResult
				local space = services.LogicalKeyboardKey.space
				if event.logicalKey.keyId ~= space.keyId then return w.KeyEventResult.ignored end
				local down = services.HardwareKeyboard.getInstance():isLogicalKeyPressed(space)
				if down and not self.spaceDown then model:tap() end
				self.spaceDown = down
				return w.KeyEventResult.handled
			end,
			child = w.Stack({fit = w.StackFit.expand, children = stack})})
	end,
})

return table.freeze(Stage)
