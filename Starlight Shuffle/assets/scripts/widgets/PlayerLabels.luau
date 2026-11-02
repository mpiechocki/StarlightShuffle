--!strict
--@client
-- Name tags under other players, and speech bubbles and typing dots over
-- their heads, at the screen points and opacities client/Chat works out each
-- frame. A bubble near the screen's edge slides back onto the screen, its
-- tail still pointing at the speaker. Bubbles that would overlap stack: the
-- newest message keeps its place over its speaker and older ones glide up
-- above it, without their tails. A name tag is a small light pill, like
-- the bubbles, its name in its player's role colour with their role icons
-- after it (client/Roles), as the chat and the app show them, and a "Zzz"
-- before it while they are idle (never, in the lobby: client/Chat does not
-- track idleness). A player wearing a shop name style or nameplate gets it
-- instead of the pill (widgets/Cosmetics): their plate, or a dark pill that
-- keeps a light name readable. Adapted from the runway project's PlayerLabels.
--
-- Labels move every frame, so each is drawn without an offscreen layer: a
-- faint name tag carries its opacity in its colours rather than through an
-- Opacity widget (its role icons, images, aside), and its shadow is a box
-- shadow, drawn directly, never a blurred text shadow. Only a label's place
-- is rebuilt as it moves; its content is built once it has popped in, and is
-- a repaint boundary of its own, so moving it shifts its recorded picture
-- instead of repainting every label. The pop-ins and typing dots step with
-- client/Chat's clock, the game's ticks: a Flutter animation would redraw the
-- whole layer at the display's rate.
local w = require("@flutter/widgets")
local engine = require("@moonbase/engine")
local game = require("@moonbase/game")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local fonts = require("@fonts/app")
local mdi = require("@icons/mdi")
local Chat = require("../client/Chat")
local Emojis = require("../client/Emojis")
local Roles = require("../client/Roles")
local EmojiText = require("./EmojiText")
local RoleIcons = require("./RoleIcons")
local Cosmetics = require("./Cosmetics")
local Looks = require("../client/Looks")
local Shop = require("../shared/Shop")

local function color(value: number): ui.Color return ui.Color({value = value}) end
local BUBBLE_FILL = color(0xf5fffbff)
local BUBBLE_INK = color(0xff43306e)
local TAIL = 10
local DOT = 5
local BUBBLE_MAX = 180 -- widest bubble
local SAY_PAD = 12 -- a speech bubble's padding either side of its text
local DOTS_WIDTH = 3 * DOT + 2 * 3.5 -- the typing dots
local EDGE = 8 -- the closest a bubble comes to the screen's edge
-- How far the tail may slide from the bubble's middle: clear of its rounded corners.
local TAIL_ROOM = 16 + TAIL / 2
-- Crowded bubbles stack this far apart, gliding into place at this rate.
local STACK_GAP = 4
local STACK_RESPONSE = 14 -- 1/s
local DOTS_HEIGHT = DOT + 2.5 -- the typing dots, with their top padding
local POP = 0.26 -- seconds a bubble part takes to pop in
local SETTLE = 0.32 -- seconds a name tag takes to settle in
local HANG_UP = ui.Offset({dx = 0, dy = -1})
-- Name tags (0xAARRGGBB, faded per tag): frosted white with a hairline edge.
-- Names on the pastel floors need a pill: a lavender role on a lavender floor
-- vanishes without one, and a dark one outweighs the avatars. A name without
-- a role colour is a soft purple-grey: no hue a role could have, and gentler
-- than the bubbles' near-black ink.
local TAG_FILL = 0xebfffbff
local TAG_INK = 0xff6e6585
local TAG_EDGE = 0x1f43306e
local TAG_SHADOW = 0x4d7a5cd6
local TAG_GAP = 4 -- between the avatar's feet and its tag
local TAG_MAX = 132 -- widest tag; longer names are cut short
local ROLE_ICON = 10
local IDLE_ICON = 11
-- Lato's line box has spare room above the capitals, so centred text reads
-- low. Lifting the name centres its cap height on the pill, level with the
-- role icons, which centre on it.
local LIFT = ui.Offset({dx = 0, dy = -1})

type Props = { read chat: Chat.Controller }
-- A label's widget, centred on its point (a bubble hung above it); a bubble
-- also keeps its width and where its tail points, a name tag its opacity and
-- roles, and each the catalog revision (emoji, roles) it was drawn with.
-- Rebuilt every frame until it has popped in.
-- A bubble's text is [big] (a few emoji alone) or [textHeight] tall; [tailed]
-- says whether it was drawn with its tail.
type Cached = { text: string, typing: boolean, dots: number, opacity: number, width: number, tail: number,
	big: boolean, textHeight: number, tailed: boolean,
	emojis: number, roles: {string}?, ranks: number, idle: boolean, settled: boolean, child: w.Widget,
	look: Shop.Look?, t: number }
-- [born]: when each label part appeared, on client/Chat's clock; [keys]:
-- each label's key, made once rather than with every move. The layer's
-- children are [shown] (label keys, in order) at [placements]; [screen],
-- [safe], [scaler] and [direction] are what the last layout saw.
-- A label in a layout: its content, where it goes (lifted that far above
-- its point when stacked, tailed while it is not) and how far it has popped in.
type Entry = { label: Chat.Label, cached: Cached, x: number, tail: number, pops: {[string]: number}, settled: boolean,
	lift: number, tailed: boolean }
-- A stacked bubble's box, centred on x.
type Placed = { x: number, half: number, top: number, bottom: number }
-- [lifts]: how far each stacked bubble is shown above its place, easing to
-- where the stack wants it; [arrangedAt]: client/Chat's clock at the last
-- layout.
type Fields = { changed: (() -> ())?, emojis: (() -> ())?, roles: (() -> ())?, contents: {[string]: Cached}, born: {[string]: number},
	keys: {[string]: w.Key}, placements: engine.LayerPlacements, shown: {string},
	screen: number?, safe: p.EdgeInsets?, scaler: p.TextScaler?, direction: ui.TextDirection?, lifts: {[string]: number},
	arrangedAt: number? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

-- [argb] with its alpha scaled by [opacity].
local function faded(argb: number, opacity: number): ui.Color
	local alpha = math.floor(bit32.rshift(argb, 24) * opacity + 0.5)
	return color(bit32.bor(bit32.lshift(alpha, 24), bit32.band(argb, 0xffffff)))
end

-- [child] popping out of its bottom edge, [t] (0..1) of the way, with a
-- slight overshoot (an ease-out-back).
local function popIn(key: string, t: number, child: w.Widget): w.Widget
	if t < 1 then
		local u = t - 1
		local value = 1 + 2.70158 * u * u * u + 1.70158 * u * u
		child = w.Opacity({opacity = math.clamp(value, 0, 1), child = w.Transform.scale({
			scale = 0.6 + 0.4 * value, alignment = p.Alignment.bottomCenter, child = child})})
	end
	return w.KeyedSubtree({key = w.ValueKey({value = key}), child = child})
end

local SAY_STYLE = p.TextStyle({fontFamily = fonts.lato, fontSize = 13, height = 1.3, color = BUBBLE_INK})
local SAY_EMOJI = EmojiText.size(13)
-- A message of nothing but a few emoji floats them big, with no bubble.
local JUMBO = 34
local JUMBO_MOST = 3

-- A rounded bubble, with a tail toward the speaker's head when [tail] (that
-- many pixels right of its middle).
local function frame(child: w.Widget, padding: p.EdgeInsets, tail: number?): w.Widget
	local box = w.Container({constraints = r.BoxConstraints({maxWidth = BUBBLE_MAX}), padding = padding,
		decoration = p.BoxDecoration({color = BUBBLE_FILL, borderRadius = p.BorderRadius.circular(16)}), child = child})
	if not tail then return box end
	return w.Column({mainAxisSize = w.MainAxisSize.min, children = {
		box,
		w.Transform.translate({offset = ui.Offset({dx = tail, dy = -TAIL / 2 - 1}), child = w.Transform.rotate({
			angle = math.pi / 4, alignment = p.Alignment.center,
			child = w.Container({width = TAIL, height = TAIL, decoration = p.BoxDecoration({color = BUBBLE_FILL,
				borderRadius = p.BorderRadius.only({bottomRight = ui.Radius.circular(2)})})}),
		})}),
	}})
end

-- Three dots that rise and brighten one after another, [cycle] (0..1) of
-- the way through their loop: client/Chat steps it with the game's ticks.
local function typingDots(cycle: number): w.Widget
	local dots: {w.Widget} = {}
	for i = 0, 2 do
		-- Each dot bumps during its half of the cycle, a beat after the last.
		local phase = (cycle - i * 0.16) % 1
		local bump = if phase < 0.5 then math.sin(phase * 2 * math.pi) else 0
		local alpha = math.floor(255 * (0.35 + 0.65 * bump) + 0.5)
		if i > 0 then table.insert(dots, w.SizedBox({width = 3.5})) end
		table.insert(dots, w.Transform.translate({offset = ui.Offset({dx = 0, dy = -2.5 * bump}),
			child = w.Container({width = DOT, height = DOT, decoration = p.BoxDecoration({
				color = color(alpha * 0x1000000 + 0x43306e), shape = p.BoxShape.circle})})}))
	end
	return w.Padding({padding = p.EdgeInsets.only({top = 2.5}),
		child = w.Row({mainAxisSize = w.MainAxisSize.min, children = dots})})
end

-- The parts of a bubble showing [text] and typing dots while [typing]: each
-- pops in on its own when it appears.
local function partsOf(text: string, typing: boolean): {string}
	local parts: {string} = {}
	if typing then table.insert(parts, if text == "" then "typing" else "typing-over") end
	if text ~= "" then table.insert(parts, "say:" .. text) end
	return parts
end

-- A player's speech and typing over their head, with its tail [tail] pixels
-- right of the bubble's middle and the typing dots [dots] through their
-- cycle; [pops] says how far each part (see partsOf) has popped in. Speech
-- takes the tailed bubble; typing alone gets a small tailed bubble of dots,
-- and typing over speech floats a dots pill above it.
local function bubble(text: string, typing: boolean, tail: number?, dots: number, pops: {[string]: number}): w.Widget
	local parts: {w.Widget} = {}
	if typing then
		if text == "" then
			table.insert(parts, popIn("typing", pops.typing or 1, frame(typingDots(dots), p.EdgeInsets.fromLTRB(12, 8, 12, 9), tail)))
		else
			table.insert(parts, popIn("typing-over", pops["typing-over"] or 1,
				frame(typingDots(dots), p.EdgeInsets.fromLTRB(9, 5, 9, 6), nil)))
			table.insert(parts, w.SizedBox({key = w.ValueKey({value = "gap"}), height = 4}))
		end
	end
	local big = if text ~= "" then EmojiText.only(text, JUMBO_MOST) else nil
	if big then
		table.insert(parts, popIn("say:" .. text, pops["say:" .. text] or 1,
			w.Padding({padding = p.EdgeInsets.only({bottom = 6}), child = EmojiText.row(big, JUMBO)})))
	elseif text ~= "" then
		table.insert(parts, popIn("say:" .. text, pops["say:" .. text] or 1,
			frame(w.Text.rich({textSpan = p.TextSpan({style = SAY_STYLE, children = (EmojiText.spans(text, SAY_EMOJI))}),
				textAlign = ui.TextAlign.center}),
				p.EdgeInsets.symmetric({horizontal = SAY_PAD, vertical = 8}), tail)))
	end
	return w.Column({mainAxisSize = w.MainAxisSize.min, children = parts})
end

-- How wide a bubble is, and how tall its text: laid out as the bubble lays
-- it out, emoji included, in the HUD's [direction].
local function measure(text: string, scaler: p.TextScaler, direction: ui.TextDirection): (number, number)
	if text == "" then return DOTS_WIDTH + 2 * 12, 0 end
	local big = EmojiText.only(text, JUMBO_MOST)
	if big then return #big * JUMBO + (#big - 1) * EmojiText.gap(JUMBO), JUMBO end
	local spans, emoji = EmojiText.spans(text, SAY_EMOJI)
	local painter = p.TextPainter({text = p.TextSpan({style = SAY_STYLE, children = spans}), textAlign = ui.TextAlign.center,
		textDirection = direction, textScaler = scaler})
	if emoji > 0 then painter:setPlaceholderDimensions(EmojiText.dimensions(emoji, SAY_EMOJI)) end
	painter:layout({maxWidth = BUBBLE_MAX - 2 * SAY_PAD})
	local width, height = math.ceil(painter.width) + 2 * SAY_PAD, math.ceil(painter.height)
	painter:dispose()
	return math.min(BUBBLE_MAX, width), height
end

-- How tall a bubble stands above its point (see bubble), with or without its tail.
local function heightOf(cached: Cached, tailed: boolean): number
	local tail = if tailed then TAIL else 0
	if cached.text == "" then return DOTS_HEIGHT + 17 + tail end -- typing alone
	local height = if cached.big then JUMBO + 6 else cached.textHeight + 16 + tail
	if cached.typing then height += DOTS_HEIGHT + 11 + 4 end -- a dots pill over it
	return height
end

-- A light pill a little below its avatar's feet, at [opacity]: the name in
-- soft grey, or in the player's role colour, and their role icons
-- after it; a "Zzz" before it when [idle]. It settles in from just above,
-- [t] (0..1) of the way.
-- A tag in a shop look: the name in its style on its plate (or a dark pill
-- for a name style alone), at [opacity], drawn at [time]; it settles in as
-- the plain one does.
local STYLED_FILL = 0xd91b1636
local function styledTag(text: string, look: Shop.Look, opacity: number, t: number, time: number): w.Widget
	local plated = Looks.plate(look.plates) ~= nil
	local label = Cosmetics.label(text, look.names, if plated then look.plates else nil, time, 10.5, nil, TAG_MAX)
	if not plated then
		label = w.Container({constraints = r.BoxConstraints({maxWidth = TAG_MAX}), padding = p.EdgeInsets.fromLTRB(7, 3, 7, 3),
			decoration = p.BoxDecoration({color = color(STYLED_FILL), borderRadius = p.BorderRadius.circular(99),
				border = p.Border.all({color = color(0x40ffffff)})}), child = label})
	end
	local tag: w.Widget = w.Padding({padding = p.EdgeInsets.only({top = TAG_GAP}), child = label})
	local value = if t >= 1 then 1 else 1 - (1 - t) ^ 3
	if value < 1 then tag = w.Transform.translate({offset = ui.Offset({dx = 0, dy = (1 - value) * -6}), child = tag}) end
	local shown = opacity * value
	return if shown < 1 then w.Opacity({opacity = shown, child = tag}) else tag
end

local function nameTag(text: string, roles: {string}?, opacity: number, t: number, idle: boolean): w.Widget
	local tint = Roles.color(roles)
	local ink = if tint then 0xff000000 + tint else TAG_INK
	local row: {w.Widget} = {}
	if idle then
		table.insert(row, w.Icon({icon = mdi.sleep, size = IDLE_ICON, color = faded(TAG_INK, opacity)}))
		table.insert(row, w.SizedBox({width = 2}))
	end
	table.insert(row, w.Flexible({child = w.Transform.translate({offset = LIFT, child = w.Text({data = text, maxLines = 1,
		overflow = w.TextOverflow.ellipsis, style = p.TextStyle({fontFamily = fonts.lato, fontSize = 10.5,
			fontWeight = ui.FontWeight.w800, letterSpacing = 0.2, color = faded(ink, opacity)})})})}))
	local icons = RoleIcons.row(roles, ROLE_ICON, 3)
	-- Images carry no colour to fade, so a faint tag fades them as a whole.
	if icons then table.insert(row, if opacity < 1 then w.Opacity({opacity = opacity, child = icons}) else icons) end
	local tag = w.Padding({padding = p.EdgeInsets.only({top = TAG_GAP}), child = w.Container({
		constraints = r.BoxConstraints({maxWidth = TAG_MAX}),
		-- A round icon at the end looks further in than a letter would.
		padding = p.EdgeInsets.fromLTRB(if idle then 5 else 7, 3, if icons then 5 else 7, 3),
		decoration = p.BoxDecoration({color = faded(TAG_FILL, opacity), borderRadius = p.BorderRadius.circular(99),
			border = p.Border.all({color = faded(TAG_EDGE, opacity)}),
			boxShadow = {p.BoxShadow({color = faded(TAG_SHADOW, opacity), blurRadius = 6, spreadRadius = -1, offset = ui.Offset({dx = 0, dy = 2})})}}),
		child = w.Row({mainAxisSize = w.MainAxisSize.min, children = row})})})
	if t >= 1 then return tag end
	local value = 1 - (1 - t) ^ 3 -- an ease-out-cubic
	return w.Opacity({opacity = value, child = w.Transform.translate({
		offset = ui.Offset({dx = 0, dy = (1 - value) * -6}), child = tag})})
end

-- Lays the labels out: each label's content (made again only when it
-- changes) and the top left corner of its slot, in order. [rebuild] says
-- whether the layer's children changed (a label came, went or changed
-- content); if not, placing them again is enough.
local function arrange(self: State): ({string}, {number}, boolean)
	local order: {string}, offsets: {number} = {}, {}
	local rebuild = false
	local live: {[string]: boolean} = {}
	local safe, scaler, screen = self.safe :: p.EdgeInsets, self.scaler :: p.TextScaler, self.screen :: number
	local chat = self.widget.chat
	local now, popping = chat.time, false
	local step = now - (self.arrangedAt or now)
	self.arrangedAt = now
	-- How far part [key] has come in [length] seconds since it appeared.
	local born = self.born
	local function progress(key: string, length: number): number
		live[key] = true
		local since = born[key]
		if not since then since = now; born[key] = now end
		local t = math.min(1, (now - since) / length)
		if t < 1 then popping = true end
		return t
	end
	local entries: {Entry} = {}
	local bubbles: {Entry} = {}
	for _, label in chat.labels do
		live[label.key] = true
		local pops: {[string]: number}, settled = {}, true
		if label.bubble then
			for _, part in partsOf(label.text, label.typing) do
				pops[part] = progress(label.key .. "|" .. part, POP)
				if pops[part] < 1 then settled = false end
			end
		else
			pops.tag = progress(label.key, SETTLE)
			settled = pops.tag >= 1
		end
		local cached = self.contents[label.key]
		local emojis, ranks = Emojis.revision(), Roles.revision()
		if not cached or cached.text ~= label.text or cached.typing ~= label.typing or cached.opacity ~= label.opacity
			or (label.bubble and cached.emojis ~= emojis)
			or (not label.bubble and (cached.roles ~= label.roles or cached.ranks ~= ranks or cached.idle ~= label.idle
				or cached.look ~= label.look or cached.t ~= label.t)) then
			local placeholder: w.Widget = w.SizedBox({})
			local width, textHeight = 0, 0
			if label.bubble then width, textHeight = measure(label.text, scaler, self.direction :: ui.TextDirection) end
			cached = { text = label.text, typing = label.typing, dots = label.dots, opacity = label.opacity, tail = 0,
				width = width, textHeight = textHeight, big = label.text ~= "" and EmojiText.only(label.text, JUMBO_MOST) ~= nil,
				tailed = true, emojis = emojis, roles = label.roles, ranks = ranks, idle = label.idle, settled = false, child = placeholder,
				look = label.look, t = label.t }
			self.contents[label.key] = cached
		end
		local x = label.x
		local tail = cached.tail
		if label.bubble then
			-- Keep the whole bubble on screen; its tail still points at the speaker.
			local half = cached.width / 2
			local low, high = safe.left + EDGE + half, screen - safe.right - EDGE - half
			x = if low <= high then math.clamp(label.x, low, high) else screen / 2
			local reach = math.max(0, half - TAIL_ROOM)
			tail = math.round(math.clamp(label.x - x, -reach, reach) * 2) / 2
		end
		local entry: Entry = { label = label, cached = cached, x = x, tail = tail, pops = pops, settled = settled, lift = 0, tailed = true }
		table.insert(entries, entry)
		if label.bubble then table.insert(bubbles, entry) end
	end
	-- Stack crowded bubbles, newest first: each keeps its place unless an
	-- earlier one is there, and then goes up above it, without its tail.
	-- (Ties, such as two players typing, by key: the same order every frame.)
	table.sort(bubbles, function(a: Entry, b: Entry): boolean
		if a.label.since ~= b.label.since then return a.label.since > b.label.since end
		return a.label.key < b.label.key
	end)
	local placed: {Placed} = {}
	for _, entry in bubbles do
		local half = entry.cached.width / 2
		local bottom = entry.label.y
		local height = heightOf(entry.cached, true)
		for _ = 1, #placed do
			local moved = false
			for _, other in placed do
				if math.abs(entry.x - other.x) < half + other.half + STACK_GAP
					and bottom > other.top - STACK_GAP and bottom - height < other.bottom + STACK_GAP then
					bottom = other.top - STACK_GAP
					height = heightOf(entry.cached, false)
					moved = true
				end
			end
			if not moved then break end
		end
		local target = entry.label.y - bottom
		entry.tailed = target < 0.5
		-- Glide there; a bubble that has just appeared starts where it belongs.
		local key = entry.label.key
		local lift = self.lifts[key] or target
		lift += (target - lift) * math.min(1, step * STACK_RESPONSE)
		if math.abs(target - lift) < 0.5 then lift = target else popping = true end
		self.lifts[key] = lift
		entry.lift = math.round(lift * 2) / 2
		table.insert(placed, { x = entry.x, half = half, top = bottom - height, bottom = bottom })
	end
	for _, entry in entries do
		local label, cached = entry.label, entry.cached
		if not cached.settled or entry.tail ~= cached.tail or label.dots ~= cached.dots or entry.tailed ~= cached.tailed then
			-- Bubbles hang above their point.
			cached.tail, cached.dots, cached.settled, cached.tailed = entry.tail, label.dots, entry.settled, entry.tailed
			local key = self.keys[label.key]
			if not key then
				key = w.ValueKey({value = label.key})
				self.keys[label.key] = key
			end
			cached.child = w.RepaintBoundary({key = key, child = w.Center({child = if label.bubble
				then w.FractionalTranslation({translation = HANG_UP, child = bubble(label.text, label.typing,
					if entry.tailed then entry.tail else nil, label.dots, entry.pops)})
				elseif label.look then styledTag(label.text, label.look, label.opacity, entry.pops.tag, label.t)
				else nameTag(label.text, label.roles, label.opacity, entry.pops.tag, label.idle)})})
			rebuild = true
		end
		table.insert(order, label.key)
		table.insert(offsets, entry.x - BUBBLE_MAX / 2 - 10)
		table.insert(offsets, label.y - entry.lift)
	end
	for key in self.contents do
		if not live[key] then self.contents[key] = nil end
	end
	for key in self.keys do
		if not live[key] then self.keys[key] = nil end
	end
	for key in self.lifts do
		if not live[key] then self.lifts[key] = nil end
	end
	for key in born do
		if not live[key] then born[key] = nil end
	end
	local shown = self.shown
	if #order ~= #shown then rebuild = true end
	for i, key in order do
		if shown[i] ~= key then rebuild = true; break end
	end
	-- Ask for the next tick's labels while anything is still popping in or gliding.
	chat.popping = popping
	return order, offsets, rebuild
end

-- Every label in its slot; [screen] is the layer's width.
local function layer(self: State, context: w.BuildContext, screen: number): w.Widget
	self.safe = w.MediaQuery.paddingOf(context)
	self.scaler = w.MediaQuery.textScalerOf(context)
	self.direction = w.Directionality.of(context)
	self.screen = screen
	local order, offsets = arrange(self)
	local children: {w.Widget} = {}
	for _, key in order do
		table.insert(children, self.contents[key].child)
	end
	self.shown = order
	self.placements:place(offsets)
	-- Moving labels only places them again (see the label callback).
	return game.PlacedLayer({placements = self.placements, childWidth = BUBBLE_MAX + 20, children = children})
end

return define("PlayerLabels", {
	createState = function(): Fields
		return { changed = nil, emojis = nil, roles = nil, contents = {}, born = {}, keys = {}, placements = engine.LayerPlacements({}),
			shown = {}, screen = nil, safe = nil, scaler = nil, direction = nil, lifts = {}, arrangedAt = nil }
	end,
	initState = function(self: State)
		local changed = function()
			if not self.mounted then return end
			-- Before the first layout nothing is known about the screen.
			if not self.screen then self:setState(function() end); return end
			local _, offsets, rebuild = arrange(self)
			if rebuild then self:setState(function() end) else self.placements:place(offsets) end
		end
		self.changed = changed
		self.widget.chat.onLabelsChanged = changed
		-- Bubbles shown before the emoji catalog loaded draw their emoji then,
		-- and name tags their roles once theirs loads.
		self.emojis = Emojis.subscribe(changed)
		self.roles = Roles.subscribe(changed)
		Roles.load()
	end,
	dispose = function(self: State)
		if self.emojis then self.emojis() end
		if self.roles then self.roles() end
		if self.widget.chat.onLabelsChanged == self.changed then
			self.widget.chat.onLabelsChanged = nil
		end
	end,
	build = function(self: State, _: w.BuildContext): w.Widget
		-- Bubbles stay within the label layer, which covers the game view.
		return w.LayoutBuilder({builder = function(inner: w.BuildContext, constraints: r.BoxConstraints): w.Widget
			return layer(self, inner, constraints.maxWidth)
		end})
	end,
})
