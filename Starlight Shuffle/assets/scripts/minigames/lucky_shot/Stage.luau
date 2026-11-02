--!strict
--@client
-- Lucky Shot's screen: one portrait game surface. The meadow fills it; the
-- shared cloud field floats in the sky (the canonical playfield, mapped onto
-- this view); the whole roster stands in the meadow below (Crowd), the local
-- player large in front on a soft halo with a small white marker. A tap on a
-- cloud fires; taps on scenery do nothing; the cycle's own buttons above take
-- their taps.
--
-- Before play: the instruction card with the +1/+2/-1 legend and the shared
-- countdown in the top panel, then a large 3, 2, 1. During play: only the
-- score and timer at the top, the slingshot reload meter at the right and
-- brief impact numbers. After: the shared results podium.
--
-- Cost per frame stays small: the crowd's avatars rebuild only when the
-- roster changes; clouds, slingshots, raindrops, lightning and labels are
-- painted from cached paths and text by one painter that repaints each frame;
-- the HUD's timer and reload meter are small widgets.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local foundation = require("@flutter/foundation")
local gestures = require("@flutter/gestures")
local game = require("@moonbase/game")
local fonts = require("@fonts/app")
local Rules = require("./Rules")
local Art = require("./Art")
local Crowd = require("./Crowd")
local Assets = require("./Assets")
local MiningArt = require("../blast_mining/Art")
local AvatarImage = require("../../widgets/AvatarImage")
local PlayerTag = require("../../widgets/PlayerTag")
local GameUi = require("../../widgets/GameUi")

local C = Rules.CONFIG
local function color(v: number): ui.Color return ui.Color({value = v}) end

local TOUCH_SLACK = 8 -- logical pixels around a cloud that still count as on it
local BURST = 0.85 -- seconds a pop or lightning plays

export type Burst = { kind: Rules.Kind, x: number, y: number, at: number, delta: number, mine: boolean, seed: number }
export type Model = {
	frame: foundation.ChangeNotifier, -- every frame
	changed: foundation.ChangeNotifier, -- roster, scores, phase and results
	ready: boolean,
	startsAt: number, endsAt: number, over: boolean,
	players: {[number]: Rules.Player}, -- by seat
	me: number?, -- our seat; nil when watching
	clouds: {[number]: Rules.Cloud},
	claimed: {[number]: boolean},
	pending: {[number]: number}, -- cloud id -> our shot sequence at it, unanswered
	reloadUntil: number, -- ours, server time
	fired: {[number]: number}, -- by seat: game.clock() of their last shot
	shots: {{ cloud: number, at: number }}, -- our pebbles in flight
	bursts: {Burst},
	standings: {Rules.Standing}?,
	reduced: boolean,
	round: () -> any,
	nextIn: () -> number,
	now: (Model) -> number,
	shoot: (Model, cloud: number) -> (),
}

-- The players other than us, in seat order, with their spots.
type Placed = { seat: number, spot: Crowd.Spot }
local function placed(model: Model): {Placed}
	local seats: {number} = {}
	for seat in model.players do
		if seat ~= model.me then table.insert(seats, seat) end
	end
	table.sort(seats)
	local spots = Crowd.layout(#seats)
	local out: {Placed} = {}
	for i, seat in seats do out[i] = { seat = seat, spot = spots[i] } end
	if model.me then table.insert(out, { seat = model.me, spot = Crowd.LOCAL }) end
	return out
end

-- An avatar's box on screen: (left, top, width, height).
local function box(spot: Crowd.Spot, width: number, height: number): (number, number, number, number)
	local w_, h_ = spot.width / 100 * width, spot.height / 100 * height
	return spot.x / 100 * width - w_ / 2, height - (spot.bottom + spot.height) / 100 * height, w_, h_
end

-- Where a spot's hand holds its slingshot.
local function hand(spot: Crowd.Spot, width: number, height: number): (number, number, number)
	local tall = spot.height / 100 * height
	return spot.x / 100 * width + tall * C.HAND_X, height - spot.bottom / 100 * height - tall * C.HAND_Y, tall
end

-- A cloud on screen now: (x, y, width, height, 0..1 of life gone).
local function onScreen(cloud: Rules.Cloud, now: number, width: number, height: number): (number, number, number, number, number)
	local x, y, f = Rules.position(cloud, now)
	local cw = cloud.size * width
	return x * width, y * height, cw, cw * 54 / 76, f
end

-- The cloud under (x, y) at server time [now], nearest first; nil for scenery.
local function cloudAt(model: Model, x: number, y: number, width: number, height: number): number?
	local now = model:now()
	local best: number? = nil
	local gap = math.huge
	for id, cloud in model.clouds do
		if not model.claimed[id] and now >= cloud.spawnAt and now < cloud.expiresAt then
			local cx, cy, cw, ch = onScreen(cloud, now, width, height)
			local dx, dy = math.abs(x - cx), math.abs(y - cy)
			if dx <= cw / 2 + TOUCH_SLACK and dy <= ch / 2 + TOUCH_SLACK and dx + dy < gap then best, gap = id, dx + dy end
		end
	end
	return best
end

-- Impact numbers, painted from text laid out once.
local labels: {[string]: p.TextPainter} = {}
local function label(text: string, size: number, color: number): p.TextPainter
	local key = text .. ":" .. size .. ":" .. color
	local painter = labels[key]
	if not painter then
		painter = p.TextPainter({text = p.TextSpan({text = text, style = p.TextStyle({fontFamily = fonts.lato, fontSize = size,
			fontWeight = ui.FontWeight.w900, color = ui.Color({value = 0xff000000 + color}),
			shadows = {ui.Shadow({color = ui.Color({value = 0xcc805481}), offset = ui.Offset({dx = 1, dy = 2}), blurRadius = 0})}})}),
			textDirection = ui.TextDirection.ltr})
		painter:layout({})
		labels[key] = painter
	end
	return painter
end

local function paintBurst(model: Model, canvas: ui.Canvas, b: Burst, width: number, height: number, clock: number)
	local t = (clock - b.at) / BURST
	if t >= 1 then return end
	local x, y = b.x * width, b.y * height
	if b.kind == "storm" then
		-- One short bolt; a gentle fade instead of a flicker with reduced motion.
		local alpha = if model.reduced then 1 - t else (1 - t) * (0.7 + 0.3 * math.cos(t * 30))
		Art.lightning(canvas, x, y + 10, if b.mine then 58 else 40, alpha)
	elseif not model.reduced or t < 0.3 then
		local color = Art.DROPS[b.kind]
		for i = 1, (if b.mine then 11 else 8) do
			local jitter = ((b.seed * 7 + i * 13) % 10) / 10
			local dx = (i - 6) * 8 + jitter * 8
			local fall = (22 + ((b.seed * 3 + i * 11) % 10) * 5.4) * t
			Art.drop(canvas, x + dx * t, y + fall, 7, color, 1 - t)
		end
	end
	local text = if b.delta > 0 then "+" .. b.delta else "−" .. math.abs(b.delta)
	local painter = label(text, if b.mine then 22 else 12, if b.delta < 0 then 0xfff0bd else 0xfff9ff)
	local rise = if model.reduced then 0 else 24 * t
	canvas:save()
	if t > 0.6 then canvas:saveLayer(nil, Art.paint(0x000000, 1 - (t - 0.6) / 0.4)) end
	painter:paint(canvas, ui.Offset({dx = x - painter.width / 2, dy = y - 26 - rise}))
	if t > 0.6 then canvas:restore() end
	canvas:restore()
end

-- Everything that moves: clouds, slingshots, pebbles, bursts and our marker.
local function paint(model: Model, canvas: ui.Canvas, size: ui.Size)
	local width, height = size.width, size.height
	if not model.ready then return end
	local now, clock = model:now(), game.clock()
	-- Our halo in the grass.
	if model.me then
		local spot = Crowd.LOCAL
		canvas:drawOval(ui.Rect.fromCenter({center = ui.Offset({dx = width / 2, dy = height - spot.bottom / 100 * height}),
			width = spot.width / 100 * width * 0.8, height = height * 0.035}), Art.glow(0xfff6db, 0.65, 10))
	end
	if now >= model.startsAt and now < model.endsAt and not model.over then
		for id, cloud in model.clouds do
			if not model.claimed[id] and now >= cloud.spawnAt and now < cloud.expiresAt then
				local x, y, cw, _, f = onScreen(cloud, now, width, height)
				local warning = cloud.expiresAt - now < C.WARNING
				local alpha = if model.pending[id] then 0.6 elseif warning then 0.45 else math.min(1, (now - cloud.spawnAt) / 0.15)
				Art.cloud(canvas, cloud.kind, x, y, cw, 1 - f, alpha)
			end
		end
	end
	-- Slingshots: ours always; a rival's only while they fire (a few at once).
	local shown = 0
	for _, entry in placed(model) do
		local mine = entry.seat == model.me
		local fired = model.fired[entry.seat]
		local since = if fired then clock - fired else math.huge
		if mine or (since < 0.3 and shown < 8) then
			if not mine then shown += 1 end
			local hx, hy, tall = hand(entry.spot, width, height)
			local kick = if since < 0.25 and not model.reduced then math.sin(since / 0.25 * math.pi) * 0.45 else 0
			local ready = if mine then 1 - math.clamp((model.reloadUntil - now) / C.RELOAD, 0, 1) else 1
			Art.slingshot(canvas, hx, hy, tall * (if mine then 0.17 else 0.15), -0.2 + kick, ready, if mine then 1 else 0.9)
		end
	end
	-- Our pebbles, a short cosmetic flight.
	if model.me then
		local hx, hy, tall = hand(Crowd.LOCAL, width, height)
		for _, shot in model.shots do
			local t = (clock - shot.at) / 0.16
			local cloud = model.clouds[shot.cloud]
			if cloud and t < 1 then
				local cx, cy = onScreen(cloud, now, width, height)
				local sx, sy = hx, hy - tall * 0.17
				canvas:drawCircle(ui.Offset({dx = sx + (cx - sx) * t, dy = sy + (cy - sy) * t}), 3.5, Art.paint(0xfff0cf))
			end
		end
		local spot = Crowd.LOCAL
		local _, top = box(spot, width, height)
		MiningArt.marker(canvas, width / 2, top - 10)
	end
	for _, b in model.bursts do paintBurst(model, canvas, b, width, height, clock) end
end

-- The roster in the meadow, rear rows first; rebuilt only when it changes.
type CrowdProps = { read model: Model }
type CrowdFields = { listener: (() -> ())? }
type CrowdState = w.State<CrowdProps, CrowdFields>
local defineCrowd = w.StatefulWidget.define :: w.StatefulWidgetFactory<CrowdProps, CrowdFields>
local CrowdView = defineCrowd("LuckyShotCrowd", {
	createState = function(): CrowdFields return { listener = nil } end,
	initState = function(self: CrowdState)
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		self.widget.model.changed:addListener(listener)
	end,
	dispose = function(self: CrowdState)
		if self.listener then self.widget.model.changed:removeListener(self.listener) end
	end,
	build = function(self: CrowdState, _context: w.BuildContext): w.Widget
		local model = self.widget.model
		return w.LayoutBuilder({builder = function(_: w.BuildContext, constraints: r.BoxConstraints): w.Widget
			local width, height = constraints.maxWidth, constraints.maxHeight
			local entries = placed(model)
			table.sort(entries, function(a: Placed, b: Placed): boolean
				if a.spot.depth ~= b.spot.depth then return a.spot.depth < b.spot.depth end
				return a.seat < b.seat
			end)
			local children: {w.Widget} = {}
			for _, entry in entries do
				local player = model.players[entry.seat]
				local left, top, bw, bh = box(entry.spot, width, height)
				local avatar = AvatarImage.body(if player then player.outfit else nil, bw, bh)
				-- Their name at their feet, in their shop look (widgets/PlayerTag).
				local figure: w.Widget = if player then w.Stack({clipBehavior = ui.Clip.none, children = {
					w.Positioned.fill({child = avatar}),
					w.Positioned({left = -30, right = -30, bottom = 4, child = w.Center({child = PlayerTag({player = player.player,
						name = player.name, size = 10, maxWidth = bw + 60})})}),
				}}) else avatar
				table.insert(children, w.Positioned({key = w.ValueKey({value = "seat" .. entry.seat}),
					left = left, top = top, width = bw, height = bh,
					child = if entry.spot.opacity < 1 then w.Opacity({opacity = entry.spot.opacity, child = figure}) else figure}))
			end
			return w.IgnorePointer({child = w.RepaintBoundary({child = w.Stack({clipBehavior = ui.Clip.hardEdge, children = children})})})
		end})
	end,
})

-- The top panel, under the cycle's head (whose timer is the time left): our
-- score; nothing while watching.
local function top(model: Model): w.Widget
	local me = if model.me then model.players[model.me] else nil
	if not me then return w.SizedBox.shrink({}) end
	return w.IgnorePointer({child = w.Align({alignment = p.Alignment.topCenter, child = w.Padding({padding = p.EdgeInsets.only({top = GameUi.HEAD}),
		child = GameUi.hud(w.Column({mainAxisSize = w.MainAxisSize.min, children = {
			GameUi.overline("Your score"),
			w.SizedBox({height = 3}),
			w.Text({data = "✦ " .. me.score, style = GameUi.style(19, GameUi.TEXT, ui.FontWeight.w800)}),
		}}), p.EdgeInsets.symmetric({horizontal = 14, vertical = 7}))})})})
end

-- The slingshot reload meter at the right: the slingshot drawing back, a
-- vertical bar, READY / RELOADING and the time left. Information only.
local function reload(model: Model): w.Widget?
	if not model.me or not model.ready or model.over then return nil end
	local now = model:now()
	if now < model.startsAt then return nil end
	local left = math.max(0, model.reloadUntil - now)
	local ready = 1 - math.clamp(left / C.RELOAD, 0, 1)
	local loading = left > 0
	return w.Positioned({right = 8, top = 0, bottom = 0, child = w.IgnorePointer({child = w.Align({alignment = p.Alignment({x = 0, y = -0.05}),
		child = GameUi.hud(w.SizedBox({width = 48, child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
			w.Text({data = "SLINGSHOT", style = GameUi.style(7, GameUi.MUTED, ui.FontWeight.w800, 0.6)}),
			w.SizedBox({height = 6}),
			w.CustomPaint({size = ui.Size({width = 28, height = 40}), painter = w.CallbackPainter({
				onPaint = function(canvas: ui.Canvas, s: ui.Size) Art.slingshot(canvas, s.width / 2, s.height, s.height, 0, ready, 1) end})}),
			w.SizedBox({height = 6}),
			w.Text({data = if loading then "RELOADING" else "READY", style = GameUi.style(7, if loading then color(0xfff0dcff) else color(0xffd4e7ca),
				ui.FontWeight.w900, 0.4)}),
			w.SizedBox({height = 6}),
			w.Container({width = 9, height = 68, decoration = p.BoxDecoration({color = color(0x22ffffff), borderRadius = p.BorderRadius.circular(5),
				border = p.Border.all({color = color(0x6ecab4d4), width = 1})}), alignment = p.Alignment.bottomCenter,
				child = w.FractionallySizedBox({heightFactor = ready, child = w.Container({decoration = p.BoxDecoration({
					color = if loading then color(0xffb191c5) else color(0xffadbea4), borderRadius = p.BorderRadius.circular(3)})})})}),
			w.SizedBox({height = 6}),
			w.Text({data = if loading then string.format("%.1fs", left) else "tap a cloud", textAlign = ui.TextAlign.center,
				style = GameUi.style(7, GameUi.MUTED, ui.FontWeight.w700)}),
		}})}), p.EdgeInsets.fromLTRB(4, 10, 4, 9))})})})
end

local function legend(kind: Rules.Kind, points: string): w.Widget
	return w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 7}), child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
		w.CustomPaint({size = ui.Size({width = 52, height = 37}), painter = w.CallbackPainter({
			onPaint = function(canvas: ui.Canvas, s: ui.Size) Art.cloud(canvas, kind, s.width / 2, s.height / 2, s.width, 1, 1) end,
			shouldRepaint = function() return false end})}),
		w.SizedBox({height = 2}),
		w.Text({data = points, style = GameUi.style(14, GameUi.CARD_TEXT, ui.FontWeight.w900)}),
	}})})
end

-- Before play: the card, then the large 3, 2, 1 in its place.
local function before(model: Model): w.Widget?
	local now = model:now()
	if model.ready and now >= model.startsAt then return nil end
	local left = if model.ready then model.startsAt - now else math.huge
	if left <= C.FINAL_COUNT then return GameUi.countdown(math.max(1, math.ceil(left))) end
	if model.ready and not model.me then
		return GameUi.instructionCard({
			GameUi.instruction("This round started without you.", true),
			w.SizedBox({height = 6}),
			GameUi.instruction("Watch, then shoot in the next one."),
		})
	end
	return GameUi.instructionCard({
		GameUi.instruction("Tap clouds to fire your slingshot. Avoid storm clouds.", true),
		w.SizedBox({height = 12}),
		w.Row({mainAxisSize = w.MainAxisSize.min, children = { legend("white", "+1"), legend("gold", "+2"), legend("storm", "−1") }}),
		w.SizedBox({height = 10}),
		GameUi.instruction("A tiny reload between shots. Top 3 win."),
		w.SizedBox({height = 12}),
		w.Text({data = "Starts automatically", style = GameUi.style(11, GameUi.CARD_MUTED, ui.FontWeight.w800, 1)}),
	})
end

local function results(model: Model): w.Widget?
	local standings = model.standings
	local round = model.round()
	if not standings or not round or round.phase ~= "results" then return nil end
	local me = if model.me then model.players[model.me] else nil
	local mine: Rules.Standing? = nil
	for _, s in standings do if me and s.player == me.player then mine = s end end
	local outfits: {[number]: {number}?} = {}
	for _, player in model.players do outfits[player.player] = player.outfit end
	local rows: {GameUi.PodiumRow} = {}
	for _, s in standings do
		table.insert(rows, { place = s.place, name = s.name, outfit = outfits[s.player], points = s.score,
			mine = mine ~= nil and s.player == mine.player })
	end
	return GameUi.podium({
		heading = if not mine then "That's a wrap"
			elseif mine.place == 1 then "On cloud nine!"
			elseif mine.place <= 3 then "A lovely little win!"
			else "Next cloud's yours.",
		summary = if mine then "You placed #" .. mine.place .. " of " .. #standings .. " with " .. mine.score
				.. (if math.abs(mine.score) == 1 then " point." else " points.")
			else "Here's who popped the most.",
		rows = rows,
		footer = "Back to the lobby in " .. math.max(0, math.ceil(model.nextIn())) .. "s",
	})
end

-- The HUD: rebuilt every frame, but it is only a few small widgets.
type HudProps = { read model: Model }
type HudFields = { listener: (() -> ())? }
type HudState = w.State<HudProps, HudFields>
local defineHud = w.StatefulWidget.define :: w.StatefulWidgetFactory<HudProps, HudFields>
local Hud = defineHud("LuckyShotHud", {
	createState = function(): HudFields return { listener = nil } end,
	initState = function(self: HudState)
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		self.widget.model.frame:addListener(listener)
	end,
	dispose = function(self: HudState)
		if self.listener then self.widget.model.frame:removeListener(self.listener) end
	end,
	build = function(self: HudState, _context: w.BuildContext): w.Widget
		local model = self.widget.model
		local layers: {w.Widget} = { w.SafeArea({child = top(model)}) }
		local meter = reload(model)
		if meter then table.insert(layers, meter) end
		local card = before(model)
		if card then table.insert(layers, w.IgnorePointer({child = card})) end
		return w.Stack({fit = w.StackFit.expand, children = layers})
	end,
})

type Props = { read model: Model }
type Fields = { painter: w.CallbackPainter?, listener: (() -> ())?, unlisten: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local Stage = {}

Stage.View = define("LuckyShotStage", {
	createState = function(): Fields return { painter = nil, listener = nil, unlisten = nil } end,
	initState = function(self: State)
		local model = self.widget.model
		self.painter = w.CallbackPainter({repaint = model.frame,
			onPaint = function(canvas: ui.Canvas, size: ui.Size) paint(model, canvas, size) end})
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		model.changed:addListener(listener)
		self.unlisten = Assets.listen(listener)
	end,
	dispose = function(self: State)
		if self.listener then self.widget.model.changed:removeListener(self.listener) end
		if self.unlisten then self.unlisten() end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local model = self.widget.model
		model.reduced = w.MediaQuery.disableAnimationsOf(context)
		local meadow = Assets.get().meadow
		local layers: {w.Widget} = { w.Container({color = color(0xff9a8fd8)}) }
		if meadow and meadow.isValid then
			table.insert(layers, w.Image({image = game.image(meadow), fit = p.BoxFit.cover, alignment = p.Alignment.bottomCenter,
				filterQuality = ui.FilterQuality.none}))
		end
		table.insert(layers, CrowdView({model = model}))
		table.insert(layers, w.CustomPaint({painter = self.painter}))
		table.insert(layers, Hud({model = model}))
		-- A tap on a cloud fires at it; anything else on the surface does nothing.
		local surface = w.LayoutBuilder({builder = function(_: w.BuildContext, constraints: r.BoxConstraints): w.Widget
			return w.Listener({behavior = r.HitTestBehavior.opaque,
				onPointerDown = function(event: gestures.PointerDownEvent)
					local id = cloudAt(model, event.localPosition.dx, event.localPosition.dy, constraints.maxWidth, constraints.maxHeight)
					if id then model:shoot(id) end
				end,
				child = w.Stack({fit = w.StackFit.expand, children = layers})})
		end})
		local stack: {w.Widget} = { surface }
		local wrap = results(model)
		if wrap then table.insert(stack, wrap) end
		return w.Stack({fit = w.StackFit.expand, children = stack})
	end,
})

return table.freeze(Stage)
