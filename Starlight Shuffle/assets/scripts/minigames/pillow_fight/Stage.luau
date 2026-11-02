--!strict
--@client
-- Pillow Fight's screen, sized from its container (portrait: Dodge and Throw
-- along the bottom; wide and short: in a column at the right). The bedroom
-- fills it; only the shown room's three or four actors stand in the arena, at
-- seats fixed for the round: you in front, rivals at the back and sides (two
-- symmetric spots in a room of three). Aiming moves only the gold ring and
-- chevron; throws, dodges and hits are short moves around the same seat.
--
-- During play the only words are names, THROW and DODGE: hearts under each
-- actor, the timer and your battle score at the top. Pillows fly on a soft arc
-- from their start and impact times. A pillow about to land on you puts the
-- red ! over your avatar and lights Dodge; your dodge shows cyan. Before play
-- the how-to examples and the group reveal (Intro), then 3, 2, 1; after it,
-- the results (Results).
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local gestures = require("@flutter/gestures")
local services = require("@flutter/services")
local game = require("@moonbase/game")
local Rules = require("./Rules")
local Model = require("./Model")
local Assets = require("./Assets")
local Art = require("./Art")
local Pieces = require("./Pieces")
local Intro = require("./Intro")
local Results = require("./Results")
local GameUi = require("../../widgets/GameUi")
local PlayerTag = require("../../widgets/PlayerTag")
local Looks = require("../../client/Looks")

local C = Rules.CONFIG

local function color(v: number): ui.Color return ui.Color({value = v}) end

type Model = Model.Model
type Rect = { x: number, y: number, w: number, h: number }
type Layout = { width: number, height: number, landscape: boolean, arena: Rect, controls: Rect, scale: number }

local function layoutFor(width: number, height: number, top: number, bottom: number): Layout
	-- Under the cycle's head and our score panel below it.
	local hud = top + GameUi.HEAD + 50
	if width > height * 1.05 then
		local side = math.clamp(width * 0.3, 190, 300)
		local arena = { x = 0, y = hud + 10, w = width - side, h = height - hud - 10 - math.max(8, bottom) }
		return { width = width, height = height, landscape = true, arena = arena,
			controls = { x = width - side + 8, y = hud + 10, w = side - 24, h = height - hud - 22 - bottom },
			scale = math.clamp(math.min(arena.h / 520, arena.w / 360), 0.47, 1.15) }
	end
	local controlsH = math.clamp(height * 0.105, 66, 92)
	local controls = { x = 14, y = height - bottom - 12 - controlsH, w = width - 28, h = controlsH }
	local arenaTop = hud + math.clamp(height * 0.05, 18, 46)
	local arena = { x = 0, y = arenaTop, w = width, h = controls.y - 18 - arenaTop }
	return { width = width, height = height, landscape = false, arena = arena, controls = controls,
		scale = math.clamp(math.min(arena.h / 560, width / 360), 0.47, 1.15) }
end

-- The seats on screen: your seat in front (or seat 1 when watching), the
-- others by seat number at the back and sides. x and foot are % of the arena;
-- w and h the box (with name and hearts) at scale 1.
type Spot = { x: number, foot: number, w: number, h: number }
local FRONT: Spot = { x = 50, foot = 99, w = 118, h = 195 }
local FOUR: {Spot} = { { x = 50, foot = 46, w = 111, h = 181 }, { x = 18, foot = 74, w = 97, h = 158 }, { x = 82, foot = 74, w = 97, h = 158 } }
local THREE: {Spot} = { { x = 26, foot = 57, w = 109, h = 180 }, { x = 74, foot = 57, w = 109, h = 180 } }
local LABELS = 33 -- the box's name and hearts below the feet, at scale 1

export type Placed = { actor: Rules.Actor, pt: Rules.Participant?, front: boolean,
	left: number, top: number, width: number, height: number, doll: number }

local function placed(model: Model, layout: Layout): {Placed}
	local seats: {number} = {}
	for seat in model.actors do table.insert(seats, seat) end
	table.sort(seats)
	local mine = if model.me then model.participants[model.me] else nil
	local front = if mine and mine.room == model.room and model.actors[mine.seat] then mine.seat else seats[1]
	local spots = if #seats <= 3 then THREE else FOUR
	local out: {Placed} = {}
	local k = 0
	for _, seat in seats do
		local spot: Spot
		if seat == front then spot = FRONT else k += 1; spot = spots[k] or spots[1] end
		local a = layout.arena
		local bw, bh = spot.w * layout.scale, spot.h * layout.scale
		local actor = model.actors[seat]
		table.insert(out, { actor = actor, pt = model.participants[actor.participant], front = seat == front,
			left = a.x + spot.x / 100 * a.w - bw / 2, top = a.y + spot.foot / 100 * a.h - bh, width = bw, height = bh,
			doll = bh - LABELS * layout.scale })
	end
	table.sort(out, function(x: Placed, y: Placed): boolean return x.top + x.height < y.top + y.height end)
	return out
end

-- Where a pillow leaves or lands on [participant]: the middle of their body.
local function pointOf(list: {Placed}, participant: number): (number?, number?)
	for _, at in list do
		if at.actor.participant == participant then return at.left + at.width / 2, at.top + at.doll * 0.45 end
	end
	return nil, nil
end

local function since(effects: {Model.Effect}, participant: number): number
	local latest = -math.huge
	for _, e in effects do if e.participant == participant and e.at > latest then latest = e.at end end
	return game.clock() - latest
end

-- Is the pillow fight on, and are we standing in it?
local function fighting(model: Model, now: number): (boolean, Rules.Actor?)
	local mine = model:mine()
	local on = not model.results and Rules.phaseAt(model.schedule, now) == "playing"
	return on and mine ~= nil and Rules.active(mine :: Rules.Actor), mine
end

local function dodging(model: Model, actor: Rules.Actor, now: number): boolean
	if now >= actor.dodgeAt and now <= actor.dodgeUntil then return true end
	return actor.participant == model.me and game.clock() < model.dodgeUntil
end

local function danger(model: Model, now: number): boolean
	local on, mine = fighting(model, now)
	if not on or not mine then return false end
	return not dodging(model, mine, now) and Rules.incoming(model.projectiles, mine, now, C.DANGER) ~= nil
end

-- A per-frame piece: rebuilt each frame from the model.
type FrameProps = { read model: Model, read layout: Layout }
type FrameFields = { listener: (() -> ())? }
type FrameState = w.State<FrameProps, FrameFields>
local defineFrame = w.StatefulWidget.define :: w.StatefulWidgetFactory<FrameProps, FrameFields>
local function frameWidget(name: string, build: (model: Model, layout: Layout) -> w.Widget)
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
		build = function(self: FrameState, _context: w.BuildContext): w.Widget
			return build(self.widget.model, self.widget.layout)
		end,
	})
end

-- One actor: the avatar (leaning, winding up or bonked around its seat), a
-- held pillow while charging, hearts and name; your red ! when in danger.
local function actorView(model: Model, at: Placed, now: number): w.Widget
	local actor, s = at.actor, at.width / 118
	local mine = actor.participant == model.me
	local charging = if mine then model.charging else actor.charging
	local out = not Rules.active(actor)
	local leaning = dodging(model, actor, now)
	local opacity = if out then 0.22 elseif leaning then 0.6 elseif now < actor.protectedUntil then 0.65 else 1
	local doll = at.doll
	local body: w.Widget = Pieces.body(at.pt, at.width, doll)
	if not model.reduced then
		local angle, dx, dy, scale = 0, 0, 0, 1
		if leaning then dx, angle = at.width * 0.28, 0.33
		elseif charging then angle, dy = -0.157, -4 * s end
		local hit = since(model.hits, actor.participant) / C.HIT_SHAKE
		if hit >= 0 and hit < 1 then
			angle += 0.14 * math.sin(hit * math.pi * 3) * (1 - hit)
			scale = 1 - 0.06 * math.sin(hit * math.pi)
		end
		local thrown = since(model.throws, actor.participant) / 0.4
		if thrown >= 0 and thrown < 1 then angle += 0.12 * math.sin(thrown * math.pi) end
		if angle ~= 0 then body = w.Transform.rotate({angle = angle, alignment = p.Alignment.bottomCenter, child = body}) end
		if scale ~= 1 then body = w.Transform.scale({scale = scale, alignment = p.Alignment.bottomCenter, child = body}) end
		if dx ~= 0 or dy ~= 0 then body = w.Transform.translate({offset = ui.Offset({dx = dx, dy = dy}), child = body}) end
	end
	local parts: {w.Widget} = {
		w.Positioned({left = 0, top = 0, width = at.width, height = doll, child = w.Opacity({opacity = opacity, child = body})}),
	}
	if charging and not out then
		local size = (if mine then 52 else 44) * s
		table.insert(parts, w.Positioned({left = at.width * 0.62 - size / 2, top = doll * 0.24 - size * 0.38, width = size, height = size * 0.76,
			child = Pieces.paint(function(canvas: ui.Canvas, size_: ui.Size)
				Art.pillow(canvas, size_.width / 2, size_.height / 2, size_.width, -0.21, 1, if mine then 0xffe9a9 else nil)
			end)}))
	end
	if out then
		table.insert(parts, w.Positioned({left = 0, right = 0, top = doll * 0.38, child = w.Center({child = w.Text({
			data = math.max(1, math.ceil(actor.respawnAt - now)) .. "s",
			style = p.TextStyle({fontSize = 14 * s, fontWeight = ui.FontWeight.w800, color = GameUi.TEXT,
				shadows = {ui.Shadow({color = color(0xff4e3564), blurRadius = 5})}})})})}))
	end
	-- Hearts, then the name.
	table.insert(parts, w.Positioned({left = 0, right = 0, top = doll + 1 * s, height = 13 * s, child = w.Center({child = w.Container({
		width = 42 * s, height = 13 * s, decoration = p.BoxDecoration({color = color(0xa6493351), borderRadius = p.BorderRadius.circular(6 * s)}),
		child = Pieces.paint(function(canvas: ui.Canvas, size: ui.Size)
			Art.hearts(canvas, size.width / 2, size.height / 2 + 0.5 * s, size.height * 0.72, actor.hp, C.HEARTS)
		end)})})}))
	local name = if at.pt then at.pt.name else "Player"
	local account = if at.pt then at.pt.account else nil
	local styled = Looks.of(account)
	-- A shop look shows as bought (widgets/PlayerTag); otherwise the game's own name pill.
	table.insert(parts, w.Positioned({left = -12 * s, right = -12 * s, top = doll + 15 * s, child = w.Center({child = if styled
		then PlayerTag({player = account, name = name, size = (if at.front then 11 else 9.5) * s, maxWidth = at.width + 24 * s})
		else w.Container({
		padding = p.EdgeInsets.symmetric({horizontal = 6 * s, vertical = 2 * s}),
		decoration = p.BoxDecoration({color = if mine then color(0xffffecd1) else color(0xdc47314f), borderRadius = p.BorderRadius.circular(5),
			border = p.Border.all({color = if mine then color(0xfffff8eb) else color(0xffcbb2da), width = 1})}),
		child = w.Text({data = name, maxLines = 1, overflow = w.TextOverflow.ellipsis,
			style = GameUi.style((if at.front then 11 else 9.5) * s, if mine then color(0xff5b4169) else GameUi.TEXT,
				if mine then ui.FontWeight.w900 else ui.FontWeight.w700)})})})}))
	if mine and danger(model, now) then
		local size, pulse = 28 * s, if model.reduced then 1 else 1 + 0.06 * math.sin(game.clock() * 15)
		table.insert(parts, w.Positioned({left = at.width / 2 - size / 2, top = -size - 4 * s, width = size, height = size,
			child = w.Transform.scale({scale = pulse, child = Pieces.badge(size)})}))
	end
	local shown: w.Widget = w.Stack({clipBehavior = ui.Clip.none, children = parts})
	local rival = model.me ~= nil and not mine
	local label = name .. ", " .. actor.hp .. (if actor.hp == 1 then " heart" else " hearts")
		.. (if mine then ", you" elseif actor.participant == model.target then ", your target" else "")
	shown = w.Semantics({label = label, button = rival, selected = actor.participant == model.target, child = shown})
	if rival then
		-- Tapping a rival aims at them; nobody moves.
		shown = w.GestureDetector({behavior = r.HitTestBehavior.opaque, onTap = function() model:choose(actor.participant) end, child = shown})
	end
	return w.Positioned({key = w.ValueKey({value = "seat" .. actor.seat}), left = at.left, top = at.top, width = at.width,
		height = at.height, child = shown})
end

-- Floor rings under the avatars: yours (with the charge meter, red in
-- danger, cyan while dodging), the target's gold one, soft shadows for others.
local function paintFloor(model: Model, list: {Placed}, now: number, canvas: ui.Canvas)
	local alarmed = danger(model, now)
	for _, at in list do
		local actor, s = at.actor, at.width / 118
		local x, y = at.left + at.width / 2, at.top + at.doll - 4 * s
		local w_, h_ = at.width * 0.84, 12 * s
		if actor.participant == model.me then
			if dodging(model, actor, now) then
				Art.ring(canvas, x, y, w_, h_, 0xb9f6f1, 0.47, 0xc6fffa, 0xc6fffa)
			elseif alarmed then
				Art.ring(canvas, x, y, w_, h_, 0xff8a96, 0.4, 0xffd8ad, 0xff767a)
			elseif model.charging then
				Art.ring(canvas, x, y, w_, h_ * 2, 0xffda84, 0.18, nil, 0xffdf9d)
				Art.charge(canvas, x, y, w_, h_ * 2, math.clamp((game.clock() - model.chargeStartedAt) / C.FULL_CHARGE, 0, 1))
			else
				Art.ring(canvas, x, y, w_, h_, 0xfff0cf, 0.4, nil, 0xfff0cf)
			end
		elseif actor.participant == model.target then
			Art.ring(canvas, x, y, w_, h_, 0xffedb4, 0.33, 0xfff0b7, 0xffe6a2)
		else
			Art.ring(canvas, x, y, w_, h_, 0x654f77, 0.2)
		end
	end
end

-- Pillows in flight, the target chevron and feathers from hits.
local function paintAir(model: Model, layout: Layout, list: {Placed}, now: number, canvas: ui.Canvas)
	local s = layout.scale
	for _, at in list do
		if at.actor.participant == model.target and Rules.active(at.actor) then
			Art.chevron(canvas, at.left + at.width / 2, at.top - 10 * s, 20 * s)
		end
	end
	for _, shot in model.projectiles do
		local x0, y0 = pointOf(list, shot.from)
		local x1, y1 = pointOf(list, shot.to)
		if x0 and y0 and x1 and y1 then
			local q = math.clamp((now - shot.startedAt) / math.max(0.01, shot.impactAt - shot.startedAt), 0, 1)
			local x = x0 + (x1 - x0) * q
			local y = y0 + (y1 - y0) * q - math.sin(q * math.pi) * C.ARC * s
			local glow = if shot.from == model.me then 0xffe9ac elseif shot.to == model.me then 0xe86383 else nil
			Art.pillow(canvas, x, y, (if shot.power == 2 then 52 else 43) * s, if model.reduced then 0 else q * 5.24, 1, glow)
		end
	end
	if model.reduced then return end
	local clock = game.clock()
	for _, hit in model.hits do
		local t = (clock - hit.at) / C.FEATHERS
		local x, y = pointOf(list, hit.participant)
		if t >= 0 and t < 1 and x and y then
			for i = 1, 7 do
				local a = (i * 2.399 + hit.at * 7) % (2 * math.pi)
				local reach = (0.5 + 0.5 * ((i * 0.618) % 1)) * 62 * s * math.sqrt(t)
				Art.feather(canvas, x + math.cos(a) * reach, y + math.sin(a) * reach * 0.6 + 40 * s * t, a + t * 2.4, 1 - t)
			end
		end
	end
end

local Arena = frameWidget("PillowFightArena", function(model: Model, layout: Layout): w.Widget
	local now = model:now()
	local list = placed(model, layout)
	local children: {w.Widget} = {
		w.Positioned({left = 0, top = 0, right = 0, bottom = 0, child = w.IgnorePointer({child = Pieces.paint(function(canvas: ui.Canvas, _: ui.Size)
			paintFloor(model, list, now, canvas)
		end)})}),
	}
	for _, at in list do table.insert(children, actorView(model, at, now)) end
	table.insert(children, w.Positioned({left = 0, top = 0, right = 0, bottom = 0, child = w.IgnorePointer({child = Pieces.paint(
		function(canvas: ui.Canvas, _: ui.Size) paintAir(model, layout, list, now, canvas) end)})}))
	return w.Stack({clipBehavior = ui.Clip.none, children = children})
end)


-- The top, under the cycle's head (whose timer is the time left): your battle
-- score (or the room you watch).
local TopHud = frameWidget("PillowFightTop", function(model: Model, _layout: Layout): w.Widget
	local mine = model:mine()
	local stat = function(label: string, child: w.Widget, width: number): w.Widget
		return GameUi.hud(w.SizedBox({width = width, child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
			GameUi.overline(label), w.SizedBox({height = 2}), child }})}), p.EdgeInsets.symmetric({horizontal = 12, vertical = 8}))
	end
	return w.IgnorePointer({child = w.Align({alignment = p.Alignment.topCenter, child = w.Padding({padding = p.EdgeInsets.only({top = GameUi.HEAD}),
		child = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
			if mine then stat("Battle score", w.Text({data = tostring(mine.score), style = GameUi.style(26, GameUi.TEXT, ui.FontWeight.w800)}), 88)
				else stat("Watching", w.Text({data = "Room " .. model.room, style = GameUi.style(20, GameUi.TEXT, ui.FontWeight.w800)}), 88),
		}})})})})
end)

-- Throw and Dodge.
local Controls = frameWidget("PillowFightControls", function(model: Model, layout: Layout): w.Widget
	local now = model:now()
	local phase = if model.results then "over" else Rules.phaseAt(model.schedule, now)
	local mine = model:mine()
	if not mine or phase == "over" or phase == "instructions" or phase == "reveal" then return w.SizedBox.shrink({}) end
	local on = fighting(model, now)
	local actor = mine :: Rules.Actor
	local charge = if model.charging then math.clamp((game.clock() - model.chargeStartedAt) / C.FULL_CHARGE, 0, 1) else 0
	local canThrow = on and now >= actor.throwReadyAt and now >= actor.stunnedUntil and model.target ~= nil
	local canDodge = on and now >= actor.dodgeReadyAt and now >= actor.stunnedUntil
	local alarmed = danger(model, now)
	local rect = layout.controls
	local gap = 8
	local throwW, throwH, dodgeW, dodgeH
	if layout.landscape then
		throwW, dodgeW = rect.w, rect.w
		throwH = math.min(110, (rect.h - gap) * 0.58)
		dodgeH = math.min(80, rect.h - gap - throwH)
	else
		dodgeW = math.clamp(rect.w * 0.22, 66, 90)
		throwW, throwH, dodgeH = rect.w - dodgeW - gap, rect.h, rect.h
	end
	local throwButton = w.Semantics({button = true, enabled = canThrow or model.charging, label = "Throw pillow. Hold, then release.",
		child = w.Listener({behavior = r.HitTestBehavior.opaque,
			-- The finger that went down on Throw keeps it until it lifts or is cancelled.
			onPointerDown = function(event: gestures.PointerDownEvent) model:press(event.pointer) end,
			onPointerUp = function(event: gestures.PointerUpEvent) model:release(event.pointer, false) end,
			onPointerCancel = function(event: gestures.PointerCancelEvent) model:release(event.pointer, true) end,
			child = Pieces.throwFace({ width = throwW, height = throwH, charge = charge, enabled = canThrow or model.charging,
				ready = canThrow and not model.charging and not alarmed })})})
	local refill = if now < actor.dodgeReadyAt then 1 - (actor.dodgeReadyAt - now) / C.DODGE_COOLDOWN else 1
	local dodgeButton = w.Semantics({button = true, enabled = canDodge, label = "Dodge",
		child = w.Listener({behavior = r.HitTestBehavior.opaque,
			onPointerDown = function(_: gestures.PointerDownEvent) model:dodge() end,
			child = Pieces.dodgeFace({ width = dodgeW, height = dodgeH, enabled = canDodge, danger = alarmed,
				active = dodging(model, actor, now), refill = refill })})})
	local content = if layout.landscape
		then w.Column({mainAxisAlignment = w.MainAxisAlignment["end"], children = { throwButton, w.SizedBox({height = gap}), dodgeButton }})
		else w.Row({children = { dodgeButton, w.SizedBox({width = gap}), throwButton }})
	return w.Positioned({left = rect.x, top = rect.y, width = rect.w, height = rect.h, child = content})
end)

-- A soft red edge while a pillow is about to land on you, and a brief flash when one does.
local Edge = frameWidget("PillowFightEdge", function(model: Model, _layout: Layout): w.Widget
	local now = model:now()
	local hurt = math.clamp(1 - (game.clock() - model.hurtAt) / C.HURT_FLASH, 0, 1)
	local alarmed = danger(model, now)
	if hurt <= 0 and not alarmed then return w.SizedBox.shrink({}) end
	return w.IgnorePointer({child = Pieces.paint(function(canvas: ui.Canvas, size: ui.Size)
		local rect = ui.Rect.fromLTWH(0, 0, size.width, size.height)
		if alarmed then
			canvas:drawRect(rect, Art.stroke(0xffd7b5, 0.9, 4))
			canvas:drawRect(rect, Art.edge(0xdf516d, 0.45, 36, 16))
		end
		if hurt > 0 then canvas:drawRect(rect, Art.edge(0xdf516d, math.floor(hurt * 10) / 10 * 0.5, 48, 22)) end
	end)})
end)

local ResultsLayer = frameWidget("PillowFightResults", function(model: Model, _layout: Layout): w.Widget
	return Results.view(model) or w.SizedBox.shrink({})
end)

local Countdown = frameWidget("PillowFightCountdown", function(model: Model, _layout: Layout): w.Widget
	local now = model:now()
	if not model.ready or model.results or Rules.phaseAt(model.schedule, now) ~= "countdown" then return w.SizedBox.shrink({}) end
	return GameUi.countdown(math.max(1, math.ceil(model.schedule.playAt - now)))
end)

type Props = { read model: Model }
type Fields = { listener: (() -> ())?, unlisten: (() -> ())?, focus: w.FocusNode?, keyDown: boolean }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local Stage = {}

Stage.View = define("PillowFightStage", {
	createState = function(): Fields return { listener = nil, unlisten = nil, focus = nil, keyDown = false } end,
	initState = function(self: State)
		local model = self.widget.model
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		model.changed:addListener(listener)
		self.unlisten = Assets.listen(listener)
		self.focus = w.FocusNode({debugLabel = "pillow-fight"})
	end,
	dispose = function(self: State)
		if self.listener then self.widget.model.changed:removeListener(self.listener) end
		if self.unlisten then self.unlisten() end
		if self.focus then self.focus:dispose() end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local model = self.widget.model
		model.reduced = w.MediaQuery.disableAnimationsOf(context)
		local insets = w.MediaQuery.paddingOf(context)
		return w.LayoutBuilder({builder = function(_: w.BuildContext, constraints: r.BoxConstraints): w.Widget
			local layout = layoutFor(constraints.maxWidth, constraints.maxHeight, insets.top, insets.bottom)
			local bedroom = Assets.get().bedroom
			local layers: {w.Widget} = { w.Container({color = color(0xffc3aed3)}) }
			if bedroom and bedroom.isValid then
				table.insert(layers, w.Image({image = game.image(bedroom), fit = p.BoxFit.cover, alignment = p.Alignment.center}))
			end
			if model.ready then
				table.insert(layers, Arena({model = model, layout = layout}))
				table.insert(layers, w.SafeArea({child = TopHud({model = model, layout = layout})}))
				table.insert(layers, Controls({model = model, layout = layout}))
				table.insert(layers, Edge({model = model, layout = layout}))
				table.insert(layers, Intro.View({model = model}))
				table.insert(layers, Countdown({model = model, layout = layout}))
			end
			table.insert(layers, ResultsLayer({model = model, layout = layout}))
			-- Space or Enter holds Throw; D dodges.
			return w.Focus({focusNode = self.focus, autofocus = true,
				onKeyEvent = function(_node: w.FocusNode, event: services.KeyEvent): w.KeyEventResult
					local keys = services.LogicalKeyboardKey
					local id = event.logicalKey.keyId
					local keyboard = services.HardwareKeyboard.getInstance()
					if id == keys.space.keyId or id == keys.enter.keyId then
						local down = keyboard:isLogicalKeyPressed(keys.space) or keyboard:isLogicalKeyPressed(keys.enter)
						if down and not self.keyDown then model:press(-1) elseif not down and self.keyDown then model:release(-1, false) end
						self.keyDown = down
						return w.KeyEventResult.handled
					elseif id == keys.keyD.keyId then
						if keyboard:isLogicalKeyPressed(keys.keyD) then model:dodge() end
						return w.KeyEventResult.handled
					end
					return w.KeyEventResult.ignored
				end,
				child = w.Listener({behavior = r.HitTestBehavior.opaque,
					child = w.Stack({fit = w.StackFit.expand, children = layers})})})
		end})
	end,
})

return table.freeze(Stage)
