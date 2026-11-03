--!strict
--@client
-- Before the fight: the how-to card through the cycle's announcement (three
-- five-second examples drawn with the game's own ring, pillow, Throw, Dodge
-- and red ! pieces, one short sentence each; the dots review an example
-- without touching the shared schedule), then, with more than one room, the
-- group reveal: everyone's head flies from one pool into their room's card,
-- yours gold as "Your group". The round starts on its own.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local game = require("@moonbase/game")
local Rules = require("./Rules")
local Model = require("./Model")
local Art = require("./Art")
local Pieces = require("./Pieces")
local GameUi = require("../../widgets/GameUi")

local C = Rules.CONFIG
local LESSONS = { "Tap a rival to aim.", "Hold. Then release.", "Red ! means dodge." }
local GOLD = 0xffe2b65a

local function color(v: number): ui.Color return ui.Color({value = v}) end

type Model = Model.Model

local function between(t: number, a: number, b: number): boolean return t >= a and t < b end

-- People for the examples: rivals from your room (else anyone), and you.
local function cast(model: Model): (Rules.Participant?, Rules.Participant?, Rules.Participant?)
	local mine = if model.me then model.participants[model.me] else nil
	local others: {Rules.Participant} = {}
	for _, pt in model.roster do
		if pt.id ~= model.me and not pt.forfeited and (not mine or pt.room == mine.room) then table.insert(others, pt) end
	end
	return others[1], others[2], mine or others[3]
end

local function lesson(model: Model, index: number, width: number, height: number): w.Widget
	local reduced = model.reduced
	local clock = game.clock()
	local a, b, me = cast(model)
	local children: {w.Widget} = {}
	if index == 1 then
		-- Tap a rival: the gold ring and chevron appear under and over them.
		local t = if reduced then 0.8 else (clock % 5) / 5
		local bw, bh = 62, height - 34
		local aimed = t >= 0.42
		for i, pt in { a, b } do
			local x = width * (if i == 1 then 0.3 else 0.7) - bw / 2
			table.insert(children, w.Positioned({left = x, top = 22, width = bw, height = bh, child = Pieces.body(pt, bw, bh)}))
		end
		table.insert(children, w.Positioned({left = 0, top = 0, width = width, height = height, child = w.IgnorePointer({child = Pieces.paint(
			function(canvas: ui.Canvas, _: ui.Size)
				local x = width * 0.3
				if aimed then
					Art.ring(canvas, x, 22 + bh - 3, bw * 0.9, 11, 0xffedb4, 0.33, 0xfff0b7, 0xffe6a2)
					Art.chevron(canvas, x, 12, 18)
				end
				if between(t, 0.3, 0.55) then
					local u = (t - 0.3) / 0.25
					canvas:drawCircle(ui.Offset({dx = x + 6, dy = 22 + bh * 0.45}), 10 + 12 * u, Art.stroke(0xfff3bf, 1 - u, 3))
				end
			end)})}))
	elseif index == 2 then
		-- Hold Throw: the meter fills and the pillow winds up; release: it flies.
		local t = if reduced then 0.5 else (clock % 5) / 5
		local charge = if t < 0.15 then 0 elseif t < 0.6 then math.min(1, (t - 0.15) / 0.36) else 0
		table.insert(children, w.Positioned({left = 0, top = 0, width = width, height = height - 64, child = Pieces.paint(
			function(canvas: ui.Canvas, size: ui.Size)
				local x, y = size.width / 2, size.height / 2 + 6
				if t < 0.6 then
					Art.pillow(canvas, x, y, 74 * (1 + 0.08 * charge), -0.21 * charge, 1, if charge >= 1 then 0xffe9a9 else nil)
				elseif t < 0.85 then
					local u = (t - 0.6) / 0.25
					Art.pillow(canvas, x + 110 * u, y - math.sin(u * math.pi) * 40 - 20 * u, 74 * (1 - 0.4 * u), u * 5, 1 - u)
				end
			end)}))
		table.insert(children, w.Positioned({left = (width - 170) / 2, bottom = 6, width = 170, height = 56,
			child = Pieces.throwFace({ width = 170, height = 56, charge = charge, enabled = true, ready = charge == 0 })}))
	else
		-- A pillow comes at you: the red !, the lit Dodge, a lean; it sails past.
		local t = if reduced then 0.4 else (clock % 3) / 3
		local bw, bh = 62, height - 34
		local x = width * 0.36
		local alarm = between(t, 0.3, 0.55)
		local lean = not reduced and between(t, 0.45, 0.85)
		local body = Pieces.body(me, bw, bh)
		if lean then body = w.Transform.translate({offset = ui.Offset({dx = bw * 0.28, dy = 0}), child = w.Transform.rotate({angle = 0.33,
			alignment = p.Alignment.bottomCenter, child = body})}) end
		table.insert(children, w.Positioned({left = x - bw / 2, top = 26, width = bw, height = bh,
			child = w.Opacity({opacity = if lean then 0.6 else 1, child = body})}))
		if alarm or reduced then
			table.insert(children, w.Positioned({left = x - 13, top = 0, width = 26, height = 26, child = Pieces.badge(26)}))
		end
		table.insert(children, w.Positioned({left = 0, top = 0, width = width, height = height, child = w.IgnorePointer({child = Pieces.paint(
			function(canvas: ui.Canvas, _: ui.Size)
				Art.ring(canvas, x, 26 + bh - 3, bw * 0.9, 11, if lean then 0xb9f6f1 elseif alarm then 0xff8a96 else 0xfff0cf, 0.45,
					if lean then 0xc6fffa elseif alarm then 0xffd8ad else nil)
				if t < 0.8 and not reduced then
					local u = t / 0.8
					Art.pillow(canvas, -20 + (width + 10) * u, 30 + bh * 0.4 - math.sin(u * math.pi) * 30, 43, u * 4,
						if u > 0.75 then (1 - u) * 4 else 1, 0xe86383)
				elseif reduced then
					Art.pillow(canvas, x - 70, 30 + bh * 0.4 - 18, 43, -0.4, 1, 0xe86383)
				end
			end)})}))
		table.insert(children, w.Positioned({right = 10, bottom = 8, width = 62, height = 62,
			child = Pieces.dodgeFace({ width = 62, height = 62, enabled = true, danger = alarm, active = lean, refill = 1 })}))
	end
	return w.ClipRRect({borderRadius = p.BorderRadius.circular(16), child = w.Container({width = width, height = height,
		decoration = p.BoxDecoration({color = color(0xffcfbadf), borderRadius = p.BorderRadius.circular(16),
			border = p.Border.all({color = color(0x55ffffff), width = 1})}),
		child = w.Stack({clipBehavior = ui.Clip.hardEdge, children = children})})})
end

local function progress(fraction: number): w.Widget
	return w.ClipRRect({borderRadius = p.BorderRadius.circular(2), child = w.Container({height = 3, color = color(0x2269527e),
		alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({widthFactor = math.clamp(fraction, 0, 1),
			child = w.Container({color = color(0xffd9b382)})})})})
end

local function instructions(model: Model, now: number, width: number, height: number): w.Widget
	if not model.me then
		return w.IgnorePointer({child = GameUi.instructionCard({
			GameUi.instruction("This match started without you.", true),
			w.SizedBox({height = 6}),
			GameUi.instruction("Watch room 1, then play the next one."),
		})})
	end
	local left = model.schedule.startsAt - now
	local auto = math.clamp(math.floor((C.INSTRUCTIONS - left) / C.LESSON) + 1, 1, 3)
	local index = model.lesson or auto
	local demoH = math.clamp(height * 0.22, 120, 176)
	local dots: {w.Widget} = {}
	for i = 1, 3 do
		table.insert(dots, w.Semantics({button = true, selected = i == index, label = "Show example " .. i .. ": " .. LESSONS[i],
			child = w.GestureDetector({behavior = r.HitTestBehavior.opaque, onTap = function() model.lesson = i end,
				child = w.SizedBox({width = 44, height = 30, child = w.Center({child = w.Container({width = 9, height = 9,
					decoration = p.BoxDecoration({shape = p.BoxShape.circle, color = if i == index then GameUi.CARD_TEXT else color(0x5569527e)})})})})})}))
	end
	return GameUi.instructionCard({
		GameUi.overline("A little sleepover rivalry", GameUi.CARD_MUTED),
		w.SizedBox({height = 12}),
		lesson(model, index, width, demoH),
		w.SizedBox({height = 12}),
		w.Semantics({liveRegion = false, child = GameUi.instruction(LESSONS[index], true)}),
		w.Row({mainAxisAlignment = w.MainAxisAlignment.center, children = dots}),
		GameUi.instruction("Each group's top three scorers earn " .. Rules.prize(1) .. ", " .. Rules.prize(2) .. " and " .. Rules.prize(3) .. " Starlights."),
		w.SizedBox({height = 12}),
		w.Text({data = "Starting in " .. math.max(0, math.ceil(left)) .. "s",
			style = GameUi.style(11, GameUi.CARD_MUTED, ui.FontWeight.w800, 1)}),
		w.SizedBox({height = 6}),
		w.SizedBox({width = 150, child = progress(left / C.INSTRUCTIONS)}),
	})
end

-- The reveal: every participant flies from the middle into their room's card.
local function reveal(model: Model, now: number, width: number): w.Widget
	local mine = if model.me then model.participants[model.me] else nil
	local rooms = model.schedule.rooms
	local gap, cardH, slot = 10, 82, 32
	local cardW = (width - gap) / 2
	local rows = math.ceil(rooms / 2)
	local height = rows * cardH + (rows - 1) * gap
	local elapsed = now - model.schedule.startsAt
	local children: {w.Widget} = {}
	for room = 1, rooms do
		local col, row = (room - 1) % 2, (room - 1) // 2
		local ours = mine ~= nil and mine.room == room
		table.insert(children, w.Positioned({left = col * (cardW + gap), top = row * (cardH + gap), width = cardW, height = cardH,
			child = w.Container({padding = p.EdgeInsets.only({top = 7}), alignment = p.Alignment.topCenter,
				decoration = p.BoxDecoration({color = if ours then color(0x22e2b65a) else color(0x0f69527e), borderRadius = p.BorderRadius.circular(14),
					border = p.Border.all({color = if ours then color(GOLD) else color(0x4469527e), width = if ours then 1.5 else 1})}),
				child = w.Text({data = if ours then "Your group" else "Room " .. room,
					style = GameUi.style(10, if ours then color(0xffa0731e) else GameUi.CARD_MUTED, ui.FontWeight.w900, 0.5)})})}))
	end
	local order = 0
	for _, pt in model.roster do
		local col, row = (pt.room - 1) % 2, (pt.room - 1) // 2
		local members = 0
		for _, other in model.roster do if other.room == pt.room and not other.forfeited then members += 1 end end
		if not pt.forfeited then
			order += 1
			local endX = col * (cardW + gap) + cardW / 2 - members * slot / 2 + (pt.seat - 1) * slot
			local endY = row * (cardH + gap) + 26
			local startX, startY = width / 2 - slot / 2, height / 2 - 24
			local u = if model.reduced then 1 else math.clamp((elapsed - order * 0.025) / 0.95, 0, 1)
			local e = 1 - (1 - u) ^ 3
			local you = pt.id == model.me
			table.insert(children, w.Positioned({key = w.ValueKey({value = "pt" .. pt.id}), left = startX + (endX - startX) * e,
				top = startY + (endY - startY) * e, width = slot, height = 50, child = w.Column({children = {
					w.Container({decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(9),
						border = p.Border.all({color = if you then color(GOLD) else color(0x00000000), width = 1.5})}),
						child = Pieces.head(pt, 26)}),
					w.SizedBox({height = 3}),
					w.Text({data = pt.name, maxLines = 1, overflow = w.TextOverflow.ellipsis, textAlign = ui.TextAlign.center,
						style = GameUi.style(7.5, if you then color(0xffa0731e) else GameUi.CARD_TEXT, ui.FontWeight.w800)}),
				}})}))
		end
	end
	return w.IgnorePointer({child = GameUi.instructionCard({
		GameUi.overline("Your sleepover crew", GameUi.CARD_MUTED),
		w.SizedBox({height = 6}),
		GameUi.instruction("Finding your group.", true),
		w.SizedBox({height = 14}),
		w.SizedBox({width = width, height = height, child = w.Stack({clipBehavior = ui.Clip.none, children = children})}),
		w.SizedBox({height = 16}),
		w.SizedBox({width = 150, child = progress(1 - elapsed / C.REVEAL)}),
	})})
end

type Props = { read model: Model }
type Fields = { listener: (() -> ())? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

local Intro = {}

Intro.View = define("PillowFightIntro", {
	createState = function(): Fields return { listener = nil } end,
	initState = function(self: State)
		local listener = function() if self.mounted then self:setState(function() end) end end
		self.listener = listener
		self.widget.model.frame:addListener(listener)
	end,
	dispose = function(self: State)
		if self.listener then self.widget.model.frame:removeListener(self.listener) end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local model = self.widget.model
		if model.results then return w.SizedBox.shrink({}) end
		local now = model:now()
		local phase = Rules.phaseAt(model.schedule, now)
		local size = w.MediaQuery.sizeOf(context)
		-- The card's inside: at most 330 wide, less its margins and padding.
		local inner = math.min(274, size.width - 92)
		local card: w.Widget? = if phase == "instructions" then instructions(model, now, inner, size.height)
			elseif phase == "reveal" then reveal(model, now, inner) else nil
		if not card then return w.SizedBox.shrink({}) end
		return w.Stack({fit = w.StackFit.expand, children = { w.IgnorePointer({child = w.Container({color = color(0x40382741)})}),
			w.SafeArea({child = w.SingleChildScrollView({child = w.ConstrainedBox({
				constraints = r.BoxConstraints({minHeight = size.height - 40}),
				child = card :: w.Widget})})}) }})
	end,
})

return table.freeze(Intro)
