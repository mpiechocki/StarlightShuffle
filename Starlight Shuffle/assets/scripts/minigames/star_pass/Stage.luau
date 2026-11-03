--!strict
--@client
-- Star Pass's screen, sized from its container (portrait: controls along the
-- bottom; wide and short: controls in a column at the right). The garden fills
-- it; the survivors stand in the crowd area (Crowd), each avatar a stable node
-- keyed by player id, so a regroup after eliminations slides everyone to their
-- new spot (REGROUP_DELAY, then REGROUP) instead of rebuilding the scene; the
-- eliminated fade upward and are removed. Stars sit at their holders' sides and
-- go straight to a new holder while a copy flies there in FLIGHT (fast, then
-- settling, turning and fading a little, as in the prototype); each burst
-- throws a few tiny stars.
--
-- At the top: the time to the burst (or the countdown, or the next wave) and
-- how many are still in. Below the field: a holder's large HOLD TO CHARGE
-- button, then up to three PASS buttons with the real players' heads and
-- names; others see a short status. Between waves the shared-style recap names
-- only that burst's eliminated players; at the end the shared podium.
--
-- Rebuilds stay small: the crowd only on roster changes; the stars, HUD,
-- controls and recap, a few widgets each, every frame.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local foundation = require("@flutter/foundation")
local gestures = require("@flutter/gestures")
local services = require("@flutter/services")
local animation = require("@flutter/animation")
local core = require("@dart/core")
local game = require("@moonbase/game")
local fonts = require("@fonts/app")
local Rules = require("./Rules")
local Crowd = require("./Crowd")
local Assets = require("./Assets")
local MiningArt = require("../blast_mining/Art")
local AvatarImage = require("../../widgets/AvatarImage")
local GameUi = require("../../widgets/GameUi")
local PlayerTag = require("../../widgets/PlayerTag")
local Looks = require("../../client/Looks")

local C = Rules.CONFIG

local function color(v: number): ui.Color return ui.Color({value = v}) end
local function ms(seconds: number): core.Duration return core.Duration({milliseconds = math.floor(seconds * 1000)}) end

export type ChargeState = "idle" | "holding" | "waiting" | "charged"
export type Burst = { player: number, at: number, x: number?, y: number? }
-- A star flying from one player to another, as in the prototype: a copy flies
-- over FLIGHT while the star itself is already with the new holder. `star`
-- names the flight (our own starts as we tap, before the server's PASSED).
export type Flight = { star: number, from: number, to: number, at: number }
export type Model = {
	frame: foundation.ChangeNotifier,
	changed: foundation.ChangeNotifier,
	ready: boolean,
	phase: Rules.Phase,
	startsAt: number, wave: number, burstAt: number, nextWaveAt: number,
	players: {[number]: Rules.Player}, -- by account id
	seats: {number}, -- account ids in seat order
	me: number?, -- our account id when we compete
	stars: {Rules.Star},
	batch: Rules.Batch?,
	departures: {[number]: number}, -- account id -> game.clock() they went
	bursts: {Burst},
	flights: {Flight},
	charge: ChargeState, chargeStartedAt: number, -- game.clock()
	passing: boolean,
	standings: {Rules.Standing}?,
	reduced: boolean,
	round: () -> any,
	nextIn: () -> number,
	now: (Model) -> number,
	-- A finger (or Space, pointer -1) goes down on the charge button, or lifts.
	press: (Model, pointer: number) -> (),
	release: (Model, pointer: number, cancelled: boolean) -> (),
	pass: (Model, target: number) -> (),
	myStar: (Model) -> Rules.Star?,
}

-- Who stands where now: survivors (and anyone leaving, at the spot they had).
type Placed = { player: number, spot: Crowd.Spot, front: boolean, leaving: boolean }
local function placed(model: Model): {Placed}
	local alive: {number}, before: {number} = {}, {}
	for _, id in model.seats do
		local pl = model.players[id]
		if pl and pl.alive then table.insert(alive, id); table.insert(before, id)
		elseif model.departures[id] then table.insert(before, id) end
	end
	local function arrange(ids: {number}): {[number]: { spot: Crowd.Spot, front: boolean }}
		local out: {[number]: { spot: Crowd.Spot, front: boolean }} = {}
		if #ids == 0 then return out end
		local front = if model.me and table.find(ids, model.me) then model.me else ids[1]
		local rest: {number} = {}
		for _, id in ids do if id ~= front then table.insert(rest, id) end end
		local spots = Crowd.layout(#rest)
		for i, id in rest do out[id] = { spot = spots[i], front = false } end
		out[front :: number] = { spot = Crowd.FRONT, front = true }
		return out
	end
	local now, then_ = arrange(alive), arrange(before)
	local out: {Placed} = {}
	for id, at in now do table.insert(out, { player = id, spot = at.spot, front = at.front, leaving = false }) end
	for id in model.departures do
		local at = then_[id]
		if at then table.insert(out, { player = id, spot = at.spot, front = at.front, leaving = true }) end
	end
	table.sort(out, function(a: Placed, b: Placed): boolean
		if a.spot.depth ~= b.spot.depth then return a.spot.depth < b.spot.depth end
		return a.player < b.player
	end)
	return out
end

type Rect = { x: number, y: number, w: number, h: number }
type Layout = { width: number, height: number, crowd: Rect, controls: Rect, landscape: boolean, scale: number }

local function layoutFor(width: number, height: number, bottomInset: number): Layout
	local landscape = width > height * 1.05
	if landscape then
		local side = math.clamp(width * 0.36, 240, 360)
		return { width = width, height = height, landscape = true, scale = math.min(1, height / 600),
			crowd = { x = 0, y = height * 0.2, w = width - side, h = height * 0.8 },
			controls = { x = width - side, y = 72, w = side, h = height - 72 - bottomInset } }
	end
	local controls = math.max(140, height * 0.176) + bottomInset
	return { width = width, height = height, landscape = false, scale = math.clamp(width / 390, 0.72, 1.3),
		crowd = { x = 0, y = height * 0.25, w = width, h = height * 0.75 - controls },
		controls = { x = 0, y = height - controls, w = width, h = controls - bottomInset } }
end

-- An avatar's box on screen.
local function box(spot: Crowd.Spot, rect: Rect): (number, number, number, number)
	local bw, bh = spot.width / 100 * rect.w, spot.height / 100 * rect.h
	return rect.x + spot.x / 100 * rect.w - bw / 2, rect.y + rect.h - (spot.bottom + spot.height) / 100 * rect.h, bw, bh
end

local REGROUP_CURVE = animation.Interval({begin = C.REGROUP_DELAY / (C.REGROUP_DELAY + C.REGROUP), ["end"] = 1,
	curve = animation.Curves.easeInOut})

-- The crowd: rebuilt on roster changes only; moves are animated by Flutter.
type CrowdProps = { read model: Model, read layout: Layout }
type CrowdFields = { listener: (() -> ())? }
type CrowdState = w.State<CrowdProps, CrowdFields>
local defineCrowd = w.StatefulWidget.define :: w.StatefulWidgetFactory<CrowdProps, CrowdFields>
local CrowdView = defineCrowd("StarPassCrowd", {
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
		local model, layout = self.widget.model, self.widget.layout
		local children: {w.Widget} = {}
		local reduced = model.reduced
		for _, entry in placed(model) do
			local pl = model.players[entry.player]
			local left, top, bw, bh = box(entry.spot, layout.crowd)
			local mine = entry.player == model.me
			if entry.leaving then
				-- A gentle fade, a little up and smaller, then gone.
				left, top, bw, bh = left + bw * 0.05, top - 12, bw * 0.9, bh * 0.9
			end
			local label = if mine then "you" else (if pl then pl.name else "")
			local parts: {w.Widget} = {}
			if entry.front and not entry.leaving then
				-- The shared soft floor halo under the foreground survivor.
				table.insert(parts, w.Positioned({left = bw * 0.12, right = bw * 0.12, bottom = -6, height = 14, child = w.Container({
					decoration = p.BoxDecoration({color = color(if mine then 0x88fff6db else 0x44fff6db), borderRadius = p.BorderRadius.circular(999)})})}))
			end
			table.insert(parts, AvatarImage.body(if pl then pl.outfit else nil, bw, bh))
			-- A small nameplate at the feet: the player's shop look when they wear one (widgets/PlayerTag).
			local account = if pl then pl.player else nil
			table.insert(parts, w.Positioned({left = -20, right = -20, bottom = -4, child = w.Center({child = if Looks.of(account) and pl
				then PlayerTag({player = account, name = pl.name, size = if entry.front then 11 else 9, maxWidth = bw + 40})
				else w.Container({
				padding = p.EdgeInsets.symmetric({horizontal = 6, vertical = 2}),
				decoration = p.BoxDecoration({color = GameUi.HUD, borderRadius = p.BorderRadius.circular(6)}),
				child = w.Text({data = label, maxLines = 1, overflow = w.TextOverflow.ellipsis,
					style = GameUi.style(if entry.front then 11 else 9, GameUi.TEXT, ui.FontWeight.w700)})})})}))
			if mine and entry.front and not entry.leaving then
				table.insert(parts, w.Positioned({left = 0, right = 0, top = -16, height = 12, child = w.CustomPaint({painter = w.CallbackPainter({
					onPaint = function(canvas: ui.Canvas, size: ui.Size) MiningArt.marker(canvas, size.width / 2, size.height / 2) end,
					shouldRepaint = function() return false end})})}))
			end
			table.insert(children, w.AnimatedPositioned({key = w.ValueKey({value = "player" .. entry.player}),
				left = left, top = top, width = bw, height = bh,
				duration = ms(if reduced then 0 elseif entry.leaving then C.EXIT else C.REGROUP_DELAY + C.REGROUP),
				curve = if entry.leaving then animation.Curves.easeOut else REGROUP_CURVE,
				child = w.AnimatedOpacity({opacity = if entry.leaving then 0 else 1, duration = ms(if reduced then 0.15 else C.EXIT),
					child = w.Stack({clipBehavior = ui.Clip.none, children = parts})})}))
		end
		return w.IgnorePointer({child = w.Stack({clipBehavior = ui.Clip.none, children = children})})
	end,
})

-- A star's centre on screen: at its holder's side.
local function starAt(model: Model, layout: Layout, holder: number): (number?, number?, boolean)
	for _, entry in placed(model) do
		if entry.player == holder and not entry.leaving then
			local left, top, bw, bh = box(entry.spot, layout.crowd)
			return left + bw * C.STAR_X, top + bh * C.STAR_Y, entry.front
		end
	end
	return nil, nil, false
end

-- Eight tiny stars from each burst; plain fades with reduced motion.
local burstPath: ui.Path? = nil
local function paintBursts(model: Model, canvas: ui.Canvas)
	local clock = game.clock()
	local path = burstPath
	if not path then
		path = ui.Path({})
		path:moveTo(0, -5); path:lineTo(1.4, -1.4); path:lineTo(5, 0); path:lineTo(1.4, 1.4)
		path:lineTo(0, 5); path:lineTo(-1.4, 1.4); path:lineTo(-5, 0); path:lineTo(-1.4, -1.4); path:close()
		burstPath = path
	end
	for _, b in model.bursts do
		local t = (clock - b.at) / C.BURST
		if t < 1 and b.x and b.y then
			local reach = if model.reduced then 0 else 65 * t
			for i = 0, 7 do
				local angle = i * math.pi / 4
				canvas:save()
				canvas:translate((b.x :: number) + math.cos(angle) * reach, (b.y :: number) + math.sin(angle) * reach)
				canvas:drawPath(path :: ui.Path, MiningArt.paint(0xfff1c4, 1 - t))
				canvas:restore()
			end
		end
	end
end

-- Stars, flights and bursts: a few widgets, every frame.
type FrameProps = { read model: Model, read layout: Layout }
type FrameFields = { listener: (() -> ())?, painter: w.CallbackPainter? }
type FrameState = w.State<FrameProps, FrameFields>
local defineFrame = w.StatefulWidget.define :: w.StatefulWidgetFactory<FrameProps, FrameFields>
local function frameWidget(name: string, build: (model: Model, layout: Layout) -> w.Widget)
	return defineFrame(name, {
		createState = function(): FrameFields return { listener = nil, painter = nil } end,
		initState = function(self: FrameState)
			local listener = function() if self.mounted then self:setState(function() end) end end
			self.listener = listener
			self.widget.model.frame:addListener(listener)
		end,
		dispose = function(self: FrameState)
			if self.listener then self.widget.model.frame:removeListener(self.listener) end
		end,
		build = function(self: FrameState, _context: w.BuildContext): w.Widget
			return build(self.widget.model, self.widget.layout)
		end,
	})
end

local StarsView = frameWidget("StarPassStars", function(model: Model, layout: Layout): w.Widget
	local kit = Assets.get()
	local children: {w.Widget} = {}
	local now, clock = model:now(), game.clock()
	-- Bursts start where their player stood.
	for _, b in model.bursts do
		if not b.x then
			for _, entry in placed(model) do
				if entry.player == b.player then
					local left, top, bw, bh = box(entry.spot, layout.crowd)
					b.x, b.y = left + bw * C.STAR_X, top + bh * C.STAR_Y
				end
			end
		end
	end
	table.insert(children, w.Positioned({left = 0, top = 0, right = 0, bottom = 0, child = w.CustomPaint({painter = w.CallbackPainter({
		onPaint = function(canvas: ui.Canvas, _size: ui.Size) paintBursts(model, canvas) end})})}))
	if model.phase == "playing" and kit.star and kit.star.isValid then
		local urgent = model.burstAt - now < 2.4
		for _, star in model.stars do
			local x, y, front = starAt(model, layout, star.holder)
			if x and y then
				local size = (if front then 53 else 43) * layout.scale
				local breathe = if model.reduced then 1 else 1 + (if urgent then 0.1 else 0.05) * math.sin(clock * (if urgent then 12 else 4))
				local s = size * breathe
				table.insert(children, w.Positioned({key = w.ValueKey({value = "star" .. star.id}),
					left = x - s / 2, top = y - s / 2, width = s, height = s,
					child = w.Container({
						decoration = p.BoxDecoration({shape = p.BoxShape.circle, boxShadow = {p.BoxShadow({
							color = color(if urgent then 0x88ffc76d else 0x66fff1c4), blurRadius = if urgent then 18 else 12})}}),
						child = w.Image({image = game.image(kit.star :: any), fit = p.BoxFit.contain, filterQuality = ui.FilterQuality.none})})}))
			end
		end
		-- Flights over the stars: out fast and settling (an ease-out), turning
		-- 150 degrees and fading to 60%; none with reduced motion.
		if not model.reduced then
			for _, f in model.flights do
				local t = (clock - f.at) / C.FLIGHT
				local ax, ay = starAt(model, layout, f.from)
				local bx, by = starAt(model, layout, f.to)
				if t >= 0 and t < 1 and ax and ay and bx and by then
					local e = 1 - (1 - t) * (1 - t)
					local s = 38 * layout.scale
					local x, y = ax + (bx - ax) * e, ay + (by - ay) * e
					table.insert(children, w.Positioned({key = w.ValueKey({value = "flight" .. f.star .. ":" .. f.at}),
						left = x - s / 2, top = y - s / 2, width = s, height = s,
						child = w.Opacity({opacity = 1 - 0.4 * e, child = w.Transform.rotate({angle = math.rad(150) * e,
							child = w.Container({decoration = p.BoxDecoration({shape = p.BoxShape.circle, boxShadow = {p.BoxShadow({
								color = color(0x66fff0b8), blurRadius = 10})}}),
								child = w.Image({image = game.image(kit.star :: any), fit = p.BoxFit.contain, filterQuality = ui.FilterQuality.none})})})})}))
				end
			end
		end
	end
	return w.IgnorePointer({child = w.Stack({clipBehavior = ui.Clip.none, children = children})})
end)

local function clockText(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return (string.format("%d:%02d", whole // 60, whole % 60))
end

-- The top panel's label, time and 0..1 of the span left: the star's fuse,
-- a game rule (the cycle's timer in the head is the time left, and counts
-- down to the start).
local function timer(model: Model, now: number): (string, string, number)
	if model.phase == "countdown" then
		return "Star bursts in", "—", 1
	elseif model.phase == "playing" then
		local span = Rules.waveDuration(model.wave, 1)
		return "Star bursts in", clockText(model.burstAt - now), math.clamp((model.burstAt - now) / span, 0, 1)
	elseif model.phase == "recap" and not (model.batch and model.batch.final) then
		return "Next stars", clockText(model.nextWaveAt - now), math.clamp((model.nextWaveAt - now) / C.RECAP, 0, 1)
	end
	return "Round over", "—", 0
end

-- The top, under the cycle's head: time to the burst (or the next stars) and
-- who is still in.
local TopHud = frameWidget("StarPassTop", function(model: Model, _layout: Layout): w.Widget
	local now = model:now()
	local label, shown, fraction = timer(model, now)
	local alive = 0
	for _, pl in model.players do if pl.alive then alive += 1 end end
	local danger = model.phase == "playing" and model.burstAt - now < 2.4
	return w.IgnorePointer({child = w.Align({alignment = p.Alignment.topCenter, child = w.Padding({padding = p.EdgeInsets.only({top = GameUi.HEAD}),
		child = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
			GameUi.hud(w.SizedBox({width = 96, child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
				GameUi.overline(label),
				w.Text({data = shown, style = GameUi.style(24, if danger then color(0xffffd27a) else GameUi.TEXT, ui.FontWeight.w800, -0.8)}),
				w.SizedBox({height = 3}),
				w.ClipRRect({borderRadius = p.BorderRadius.circular(2), child = w.Container({height = 3, color = color(0x33ffffff),
					alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({widthFactor = fraction,
						child = w.Container({color = if danger then color(0xffffd27a) else GameUi.MUTED})})})}),
			}})}), p.EdgeInsets.symmetric({horizontal = 12, vertical = 7})),
			w.SizedBox({width = 8}),
			GameUi.hud(w.Column({mainAxisSize = w.MainAxisSize.min, children = {
				GameUi.overline("Still in"),
				w.Text.rich({textSpan = p.TextSpan({children = {
					p.TextSpan({text = tostring(alive), style = GameUi.style(24, GameUi.TEXT, ui.FontWeight.w800)}),
					p.TextSpan({text = " / " .. #model.seats, style = GameUi.style(13, GameUi.MUTED, ui.FontWeight.w700)}),
				}})}),
			}}), p.EdgeInsets.symmetric({horizontal = 12, vertical = 7})),
		}})})})})
end)

local function status(model: Model): string?
	local me = if model.me then model.players[model.me] else nil
	if model.phase == "playing" then
		local star = model:myStar()
		if star then
			return if model.charge == "charged" then "Charged. Pass it on!"
				elseif model.charge == "idle" then "Your star. Hold to charge."
				else "Charging…"
		end
		if me and me.alive then return "Keep your hands free." end
		return if me then "You're out — keep watching!" else "Watching this match."
	elseif model.phase == "recap" then
		return if me and me.alive then "A little closer to the stars." else "The stars keep moving…"
	end
	return nil
end

-- A recipient: their head, real name and PASS.
local function target(model: Model, id: number, ready: boolean): w.Widget
	local pl = model.players[id]
	local name = if pl then pl.name else "Player"
	return w.Expanded({key = w.ValueKey({value = "target" .. id}), child = w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 4}),
		child = w.Semantics({button = true, label = "Pass to " .. name, child = w.GestureDetector({
			onTap = if ready then function() model:pass(id) end else nil,
			child = w.Opacity({opacity = if ready then 1 else 0.55, child = w.Container({
				height = 64, padding = p.EdgeInsets.symmetric({horizontal = 8}),
				decoration = p.BoxDecoration({color = GameUi.ROW, borderRadius = p.BorderRadius.circular(14),
					border = p.Border.all({color = color(0xffe2b65a), width = 1.2})}),
				child = w.Row({children = {
					w.ClipRRect({borderRadius = p.BorderRadius.circular(8), child = w.Container({color = color(0x33ffffff),
						child = AvatarImage.head(if pl then pl.outfit else nil, 38)})}),
					w.SizedBox({width = 7}),
					w.Expanded({child = w.Column({mainAxisAlignment = w.MainAxisAlignment.center, crossAxisAlignment = w.CrossAxisAlignment.start,
						children = {
							w.Text({data = name, maxLines = 1, overflow = w.TextOverflow.ellipsis, style = GameUi.style(13, GameUi.TEXT, ui.FontWeight.w800)}),
							w.Text({data = "PASS ↗", style = GameUi.style(10, color(0xffffd98a), ui.FontWeight.w900, 0.6)}),
						}})}),
				}})})})})})})})
end

-- The bottom (or side) controls: charge, then pass; otherwise a short status.
local Controls = frameWidget("StarPassControls", function(model: Model, layout: Layout): w.Widget
	local kit = Assets.get()
	local star = if model.phase == "playing" then model:myStar() else nil
	local rect = layout.controls
	local content: w.Widget
	if star and model.charge == "charged" then
		local ready = not model.passing and model:now() - star.receivedAt >= C.CATCH
		local buttons: {w.Widget} = {}
		for _, id in star.choices do table.insert(buttons, target(model, id, ready)) end
		local rows: w.Widget = if layout.landscape
			then w.Column({mainAxisSize = w.MainAxisSize.min, children = (function()
				local out: {w.Widget} = {}
				for _, b in buttons do table.insert(out, w.SizedBox({height = 72, child = w.Row({children = {b}})})) end
				return out
			end)()})
			else w.Row({children = buttons})
		content = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
			GameUi.hud(w.Text({data = "Tap someone to pass", style = GameUi.style(14, color(0xffffe6a6), ui.FontWeight.w800)}),
				p.EdgeInsets.symmetric({horizontal = 12, vertical = 4})),
			w.SizedBox({height = 8}),
			rows,
		}})
	elseif star then
		local holding = model.charge == "holding"
		local fill = if model.charge == "waiting" then 1 elseif holding then math.clamp((game.clock() - model.chargeStartedAt) / C.CHARGE, 0, 1) else 0
		content = w.Semantics({button = true, label = "Hold to charge your star", child = w.Listener({
			behavior = r.HitTestBehavior.opaque,
			-- One finger holds; others are ignored (Client keeps the first).
			onPointerDown = function(event: gestures.PointerDownEvent) model:press(event.pointer) end,
			onPointerUp = function(event: gestures.PointerUpEvent) model:release(event.pointer, false) end,
			onPointerCancel = function(event: gestures.PointerCancelEvent) model:release(event.pointer, true) end,
			child = w.Container({height = 78, margin = p.EdgeInsets.symmetric({horizontal = 12}),
				padding = p.EdgeInsets.symmetric({horizontal = 16}),
				decoration = p.BoxDecoration({color = if holding then GameUi.ACTION else GameUi.ROW, borderRadius = p.BorderRadius.circular(18),
					border = p.Border.all({color = color(0xffe2b65a), width = 1.5})}),
				child = w.Row({children = {
					if kit.star and kit.star.isValid then w.Image({image = game.image(kit.star :: any), width = 44, height = 44,
						filterQuality = ui.FilterQuality.none}) else w.SizedBox({width = 44}),
					w.SizedBox({width = 12}),
					w.Expanded({child = w.Column({mainAxisAlignment = w.MainAxisAlignment.center, crossAxisAlignment = w.CrossAxisAlignment.stretch,
						children = {
							w.Text({data = if model.charge == "waiting" then "CHARGED…" elseif holding then "CHARGING…" else "HOLD TO CHARGE",
								style = GameUi.style(16, GameUi.TEXT, ui.FontWeight.w900, 1)}),
							w.SizedBox({height = 8}),
							w.ClipRRect({borderRadius = p.BorderRadius.circular(4), child = w.Container({height = 8, color = color(0x33ffffff),
								alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({widthFactor = fill,
									child = w.Container({color = color(0xffffd98a)})})})}),
						}})}),
				}})})})})
	else
		local me = if model.me then model.players[model.me] else nil
		local line = if model.phase == "playing" and not (me and me.alive) then status(model) else nil
		if not line then return w.SizedBox.shrink({}) end
		content = w.Center({child = GameUi.hud(w.Text({data = line, textAlign = ui.TextAlign.center,
			style = GameUi.style(14, GameUi.SOFT, ui.FontWeight.w700)}), p.EdgeInsets.symmetric({horizontal = 16, vertical = 12}))})
	end
	return w.Positioned({left = rect.x, top = rect.y, width = rect.w, height = rect.h,
		child = w.Center({child = w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 8}), child = content})})})
end)

-- The short status line under the top panels.
local Banner = frameWidget("StarPassBanner", function(model: Model, _layout: Layout): w.Widget
	local line = status(model)
	if not line or model.phase == "countdown" then return w.SizedBox.shrink({}) end
	return w.IgnorePointer({child = w.Align({alignment = p.Alignment.topCenter, child = w.Padding({padding = p.EdgeInsets.only({top = GameUi.HEAD + 66}),
		child = w.Text({data = line, textAlign = ui.TextAlign.center, style = p.TextStyle({fontFamily = fonts.lato, fontSize = 18,
			fontWeight = ui.FontWeight.w800, fontStyle = ui.FontStyle.italic, color = GameUi.TEXT,
			shadows = {ui.Shadow({color = color(0x99473655), blurRadius = 6, offset = ui.Offset({dx = 0, dy = 1})})}})})})})})
end)

-- Before the first wave: the card, then the large 3, 2, 1.
local Prep = frameWidget("StarPassPrep", function(model: Model, _layout: Layout): w.Widget
	if not model.ready or model.phase ~= "countdown" then return w.SizedBox.shrink({}) end
	local left = model.startsAt - model:now()
	if left <= C.FINAL_COUNT then return GameUi.countdown(math.max(1, math.ceil(left))) end
	if not model.me then
		return w.IgnorePointer({child = GameUi.instructionCard({
			GameUi.instruction("This match started without you.", true),
			w.SizedBox({height = 6}),
			GameUi.instruction("Watch, then play the next one."),
		})})
	end
	return w.IgnorePointer({child = GameUi.instructionCard({
		GameUi.instruction("Got a glowing star? Hold to charge, then tap a player to pass. Don't hold it when it bursts!", true),
		w.SizedBox({height = 10}),
		GameUi.instruction("The tick-tock gets faster near the burst."),
		w.SizedBox({height = 12}),
		w.Text({data = "Starts automatically", style = GameUi.style(11, GameUi.CARD_MUTED, ui.FontWeight.w800, 1)}),
	})})
end)

-- Between waves: only this burst's eliminated, with the time to the next wave.
local Recap = frameWidget("StarPassRecap", function(model: Model, layout: Layout): w.Widget
	local batch = model.batch
	local now = model:now()
	if not batch or now < batch.at or now >= batch.nextAt or #batch.players == 0 then return w.SizedBox.shrink({}) end
	local t, left = now - batch.at, batch.nextAt - now
	local opacity = math.min(math.clamp(t / C.RECAP_IN, 0, 1), math.clamp(left / C.RECAP_OUT, 0, 1))
	local rise = if model.reduced then 0 else (1 - math.clamp(t / C.RECAP_IN, 0, 1)) * 14
	local rows: {w.Widget} = {}
	for _, id in batch.players do
		local pl = model.players[id]
		table.insert(rows, w.Container({key = w.ValueKey({value = "out" .. id}), height = 53, margin = p.EdgeInsets.only({bottom = 7}),
			padding = p.EdgeInsets.symmetric({horizontal = 10}),
			decoration = p.BoxDecoration({color = GameUi.ROW, borderRadius = p.BorderRadius.circular(12),
				border = if id == model.me then p.Border.all({color = GameUi.BORDER, width = 1}) else nil}),
			child = w.Row({children = {
				w.ClipRRect({borderRadius = p.BorderRadius.circular(8), child = w.Container({color = color(0x33ffffff),
					child = AvatarImage.head(if pl then pl.outfit else nil, 38)})}),
				w.SizedBox({width = 10}),
				w.Expanded({child = w.Text({data = if pl then pl.name else "Player", maxLines = 1, overflow = w.TextOverflow.ellipsis,
					style = GameUi.style(15, GameUi.TEXT, ui.FontWeight.w800)})}),
				if id == model.me then w.Text({data = "you", style = GameUi.style(10, GameUi.MUTED, ui.FontWeight.w700)}) else w.SizedBox.shrink({}),
			}})}))
	end
	local list: w.Widget
	if layout.landscape and #rows > 2 then
		-- Two columns when short.
		local left_: {w.Widget}, right_: {w.Widget} = {}, {}
		for i, row in rows do table.insert(if i % 2 == 1 then left_ else right_, row) end
		list = w.Row({crossAxisAlignment = w.CrossAxisAlignment.start, children = {
			w.Expanded({child = w.Column({children = left_})}), w.SizedBox({width = 7}), w.Expanded({child = w.Column({children = right_})})}})
	else
		list = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = rows})
	end
	local survivors = if batch.survivors == 1 then "One star left standing."
		else batch.survivors .. " players remain"
	return w.IgnorePointer({child = w.Opacity({opacity = opacity, child = w.Stack({fit = w.StackFit.expand, children = {
		w.Container({color = color(0x40140c22)}),
		w.Center({child = w.Transform.translate({offset = ui.Offset({dx = 0, dy = rise}), child = w.Container({
			width = math.min(310 * layout.scale, layout.width - 32),
			padding = p.EdgeInsets.fromLTRB(16, 18, 16, 14),
			decoration = p.BoxDecoration({color = GameUi.PANEL, borderRadius = p.BorderRadius.circular(GameUi.RADIUS),
				border = p.Border.all({color = GameUi.BORDER, width = 1})}),
			child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
				w.Text({data = "Out this round", textAlign = ui.TextAlign.center, style = GameUi.style(26, GameUi.TEXT, ui.FontWeight.w700, -0.5, true)}),
				w.SizedBox({height = 12}),
				list,
				w.SizedBox({height = 4}),
				w.Text({data = survivors, textAlign = ui.TextAlign.center, style = GameUi.style(13, GameUi.SOFT, ui.FontWeight.w700)}),
				w.SizedBox({height = 10}),
				w.ClipRRect({borderRadius = p.BorderRadius.circular(2), child = w.Container({height = 3, color = color(0x33ffffff),
					alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({widthFactor = math.clamp(left / C.RECAP, 0, 1),
						child = w.Container({color = color(0xffffd98a)})})})}),
			}}),
		})})}),
	}})})})
end)

local function results(model: Model): w.Widget?
	local standings = model.standings
	local round = model.round()
	if not standings or not round or round.phase ~= "results" then return nil end
	local mine: Rules.Standing? = nil
	for _, s in standings do if s.player == model.me then mine = s end end
	local rows: {GameUi.PodiumRow} = {}
	for _, s in standings do
		local pl = model.players[s.player]
		table.insert(rows, { place = s.place, name = s.name, outfit = if pl then pl.outfit else nil, points = s.passes,
			mine = s.player == model.me, metric = s.passes .. (if s.passes == 1 then " pass" else " passes") })
	end
	return GameUi.podium({
		heading = if not mine or mine.place == 1 then "Written in the stars."
			elseif mine.place <= 3 then "So close to the stars!"
			else "Out among the stars.",
		summary = if not mine then "You watched this match."
			elseif mine.place == 1 then "You're the last star standing!"
			else "You placed #" .. mine.place .. " of " .. #standings .. ". Top three win.",
		rows = rows,
		footer = "Back to the lobby in " .. math.max(0, math.ceil(model.nextIn())) .. "s",
	})
end

type Props = { read model: Model }
type Fields = { listener: (() -> ())?, unlisten: (() -> ())?, focus: w.FocusNode?, spaceDown: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local Stage = {}

Stage.View = define("StarPassStage", {
	createState = function(): Fields return { listener = nil, unlisten = nil, focus = nil, spaceDown = false } end,
	initState = function(self: State)
		local model = self.widget.model
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		model.changed:addListener(listener)
		self.unlisten = Assets.listen(listener)
		self.focus = w.FocusNode({debugLabel = "star-pass"})
	end,
	dispose = function(self: State)
		if self.listener then self.widget.model.changed:removeListener(self.listener) end
		if self.unlisten then self.unlisten() end
		if self.focus then self.focus:dispose() end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local model = self.widget.model
		model.reduced = w.MediaQuery.disableAnimationsOf(context)
		local inset = w.MediaQuery.paddingOf(context).bottom
		return w.LayoutBuilder({builder = function(_: w.BuildContext, constraints: r.BoxConstraints): w.Widget
			local layout = layoutFor(constraints.maxWidth, constraints.maxHeight, inset)
			local garden = Assets.get().garden
			local layers: {w.Widget} = { w.Container({color = color(0xfff1dbe2)}) }
			if garden and garden.isValid then
				table.insert(layers, w.Image({image = game.image(garden), fit = p.BoxFit.cover, alignment = p.Alignment.topCenter}))
			end
			table.insert(layers, CrowdView({model = model, layout = layout}))
			table.insert(layers, StarsView({model = model, layout = layout}))
			table.insert(layers, w.SafeArea({child = TopHud({model = model, layout = layout})}))
			table.insert(layers, w.SafeArea({child = Banner({model = model, layout = layout})}))
			table.insert(layers, Controls({model = model, layout = layout}))
			table.insert(layers, Prep({model = model, layout = layout}))
			table.insert(layers, Recap({model = model, layout = layout}))
			local wrap = results(model)
			if wrap then table.insert(layers, wrap) end
			-- The field takes no taps: only the controls act. Space holds to charge.
			return w.Focus({focusNode = self.focus, autofocus = true,
				onKeyEvent = function(_node: w.FocusNode, event: services.KeyEvent): w.KeyEventResult
					local space = services.LogicalKeyboardKey.space
					if event.logicalKey.keyId ~= space.keyId then return w.KeyEventResult.ignored end
					local down = services.HardwareKeyboard.getInstance():isLogicalKeyPressed(space)
					if down and not self.spaceDown then model:press(-1) elseif not down and self.spaceDown then model:release(-1, false) end
					self.spaceDown = down
					return w.KeyEventResult.handled
				end,
				child = w.Listener({behavior = r.HitTestBehavior.opaque,
					child = w.Stack({fit = w.StackFit.expand, children = layers})})})
		end})
	end,
})

return table.freeze(Stage)
