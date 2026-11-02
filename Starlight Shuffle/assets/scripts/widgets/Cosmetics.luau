--!strict
--@client
-- Draws the shop's cosmetics (client/Looks) for the shop and the name tags
-- over avatars: a name in its colour or flowing gradient, a plate behind it
-- with its painted ornament and art, an avatar with its glow following its
-- silhouette, and the two currencies' pixel-art icons (Stars' gold coin and
-- Starlight's lavender four-point sparkle). Animated looks take the time [t]
-- in seconds; a static look ignores it, and reduced motion passes 0. Names on
-- a plate get a thin outline in the plate's contrast colour, under the
-- letters, so the chosen colour or effect is never changed.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local fonts = require("@fonts/app")
local foundation = require("@flutter/foundation")
local Looks = require("../client/Looks")
local Art = require("../minigames/blast_mining/Art")
local AvatarImage = require("./AvatarImage")

local paint, stroke = Art.paint, Art.stroke

local function color(argb: number): ui.Color return ui.Color({value = argb}) end
local function opaque(rgb: number): ui.Color return color(0xff000000 + rgb) end
local function offset(x: number, y: number): ui.Offset return ui.Offset({dx = x, dy = y}) end

local Cosmetics = {}

Cosmetics.DEFAULT_INK = 0xfaf6ff

-- Icons ----------------------------------------------------------------

-- Stars: the supplied 21 x 22 gold coin, pixel for pixel.
local COIN_PALETTE: {[string]: number} = {
	a = 0xffcf972e, b = 0xffe0ba72, c = 0xffe7c88f, d = 0xfffdeed0, e = 0xfffffdf0,
	f = 0xfffffefd, g = 0xfffef7e7, h = 0xffac722b, i = 0xffdda35b, j = 0xffc48538,
}
local COIN = {
	".......aaaaaaa.......", ".....aabccdcdbaa.....", "....accbaaaaaddba....", "...accaadddddaadda...",
	"..acbaddddddddeadda..", ".acbadddddbfdddeadda.", ".acaddbdddbfddbdeada.", "abbadddbdbdbfbdddadca",
	"acaddddbbbgbbbfffeada", "adadddagggddddbbdcada", "acaddcdaaaddbbddcdada", "adadcddddadbdddcdcada",
	"acdadddadadbdacdcadca", "acdaddadddaddcacdadca", "haddadddddadcdcdaddah", ".haddadddddcdcdaddah.",
	".hiaddaaddcdcaaddaih.", "..hiadddaaaaaddcaih..", "...hiaaccdddccaaih...", "....hjiaaaaaaaijh....",
	".....hhijijijihh.....", ".......hhhhhhh.......",
}
-- Starlight: the supplied 24 x 24 sparkle, as its four flat layers.
local SPARKLE = {
	{ 0x7754ae, "M10 0h4v5h2v3h3v2h5v4h-5v2h-3v3h-2v5h-4v-5H8v-3H5v-2H0v-4h5V8h3V5h2z" },
	{ 0xefd6ff, "M11 1h2v5h2v3h3v2h5v2h-5v2h-3v3h-2v5h-2v-5H9v-3H6v-2H1v-2h5V9h3V6h2z" },
	{ 0xbfa0f0, "M11 5h2v4h2v2h4v2h-4v2h-2v4h-2v-4H9v-2H5v-2h4V9h2z" },
	{ 0xfff0ff, "M11 6h1v5H7v1h5V7h1v6h-2v-1H7v-1h4z" },
}

-- An SVG path of M, h, v, H, V and z commands as a ui.Path.
local function svgPath(d: string): ui.Path
	local path = ui.Path({})
	local x, y = 0, 0
	for command, number in string.gmatch(d, "(%a)([%-%d%.]*)") do
		local n = tonumber(number) or 0
		if command == "M" then
			local px, py = string.match(d, "M([%-%d%.]+) ([%-%d%.]+)")
			x, y = tonumber(px) or 0, tonumber(py) or 0
			path:moveTo(x, y)
		elseif command == "h" then x += n; path:lineTo(x, y)
		elseif command == "v" then y += n; path:lineTo(x, y)
		elseif command == "H" then x = n; path:lineTo(x, y)
		elseif command == "V" then y = n; path:lineTo(x, y)
		elseif command == "z" then path:close() end
	end
	return path
end

local sparklePaths: {ui.Path}? = nil
local function paintSparkle(canvas: ui.Canvas, size: ui.Size)
	if not sparklePaths then
		local made: {ui.Path} = {}
		for i, layer in SPARKLE do made[i] = svgPath(layer[2] :: string) end
		sparklePaths = made
	end
	canvas:save()
	canvas:scale(size.width / 24, size.height / 24)
	for i, layer in SPARKLE do canvas:drawPath((sparklePaths :: {ui.Path})[i], paint(layer[1] :: number)) end
	canvas:restore()
end

local function paintCoin(canvas: ui.Canvas, size: ui.Size)
	local cell = math.min(size.width / 21, size.height / 22)
	local left, top = (size.width - 21 * cell) / 2, (size.height - 22 * cell) / 2
	for row, line in COIN do
		for col = 1, #line do
			local argb = COIN_PALETTE[string.sub(line, col, col)]
			if argb then
				-- A hair of overlap keeps the cells from showing seams.
				canvas:drawRect(ui.Rect.fromLTWH(left + (col - 1) * cell, top + (row - 1) * cell, cell + 0.35, cell + 0.35),
					paint(bit32.band(argb, 0xffffff)))
			end
		end
	end
end

-- [currency]'s icon, [size] square.
function Cosmetics.icon(currency: "stars" | "starlight", size: number): w.Widget
	return w.SizedBox({width = size, height = size, child = w.CustomPaint({painter = w.CallbackPainter({
		onPaint = if currency == "stars" then paintCoin else paintSparkle})})})
end

-- Names ----------------------------------------------------------------

-- A crisp outline from four hard shadows, plus a soft drop for depth.
local outlines: {[number]: {ui.Shadow}} = {}
local function outlineOf(rgb: number): {ui.Shadow}
	local made = outlines[rgb]
	if made then return made end
	local c = opaque(rgb)
	made = {
		ui.Shadow({color = c, offset = offset(0.7, 0), blurRadius = 0.4}), ui.Shadow({color = c, offset = offset(-0.7, 0), blurRadius = 0.4}),
		ui.Shadow({color = c, offset = offset(0, 0.7), blurRadius = 0.4}), ui.Shadow({color = c, offset = offset(0, -0.7), blurRadius = 0.4}),
		ui.Shadow({color = color(0x66000000), offset = offset(0, 1), blurRadius = 2}),
	}
	outlines[rgb] = made
	return made
end
local SOFT = { ui.Shadow({color = color(0x88000000), offset = offset(0, 1), blurRadius = 2}) }

export type NameOptions = {
	size: number,
	ink: number?, -- the default name's colour (0xRRGGBB)
	outline: number?, -- a contrast outline under the letters
	weight: ui.FontWeight?,
	maxLines: number?,
	soft: boolean?, -- a soft drop shadow when there is no outline
}

local function textStyle(options: NameOptions, fill: ui.Color, shadows: {ui.Shadow}?): p.TextStyle
	return p.TextStyle({fontFamily = fonts.lato, fontSize = options.size, fontWeight = options.weight or ui.FontWeight.w800,
		letterSpacing = 0.2, color = fill, shadows = shadows})
end

local function line(text: string, style: p.TextStyle, options: NameOptions): w.Widget
	return w.Text({data = text, style = style, maxLines = options.maxLines or 1, overflow = w.TextOverflow.ellipsis,
		softWrap = false, textAlign = ui.TextAlign.center})
end

-- [text] in name style [id] at time [t].
function Cosmetics.name(text: string, id: string?, t: number, options: NameOptions): w.Widget
	local look = Looks.name(id)
	local under = if options.outline then outlineOf(options.outline :: number) elseif options.soft then SOFT else nil
	local gradient = if look then look.gradient else nil
	if not look or not gradient then
		local rgb = if look and look.color then look.color :: number else options.ink or Cosmetics.DEFAULT_INK
		return line(text, textStyle(options, opaque(rgb), under), options)
	end
	-- A loop of the gradient two and a half names wide, flowing along over its period.
	local colors: {ui.Color} = {}
	for i, rgb in gradient do colors[i] = opaque(rgb) end
	table.insert(colors, opaque(gradient[1]))
	local phase = (t / (look.period or 5)) % 1
	local shift = -5 * phase
	local layers: {w.Widget} = {}
	local glow = look.glow
	if under or glow then
		local shadows: {ui.Shadow} = if under then table.clone(under) else {}
		if glow then table.insert(shadows, ui.Shadow({color = color(0x99000000 + glow), blurRadius = 5})) end
		table.insert(layers, line(text, textStyle(options, color(0x00000000), shadows), options))
	end
	table.insert(layers, w.ShaderMask({blendMode = ui.BlendMode.srcIn, shaderCallback = function(rect: ui.Rect): ui.Shader
		return p.LinearGradient({colors = colors, begin = p.Alignment({x = -1 + shift, y = 0}), ["end"] = p.Alignment({x = 4 + shift, y = 0}),
			tileMode = ui.TileMode.repeated}):createShader({rect = rect})
	end, child = line(text, textStyle(options, opaque(0xffffff)), options)}))
	if #layers == 1 then return layers[1] end
	return w.Stack({alignment = p.Alignment.center, children = layers})
end

-- Plates ---------------------------------------------------------------

-- A unit five-point star path (radius 1), made once.
local star: ui.Path? = nil
local function starPath(): ui.Path
	if star then return star end
	local s = ui.Path({})
	for i = 0, 9 do
		local a = i * math.pi / 5 - math.pi / 2
		local r = if i % 2 == 1 then 0.42 else 1
		if i == 0 then s:moveTo(math.cos(a) * r, math.sin(a) * r) else s:lineTo(math.cos(a) * r, math.sin(a) * r) end
	end
	s:close()
	star = s
	return s
end

local function drawStar(canvas: ui.Canvas, x: number, y: number, r: number, rgb: number, alpha: number, angle: number)
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(angle)
	canvas:scale(r, r)
	canvas:drawPath(starPath(), paint(rgb, alpha))
	canvas:restore()
end

-- A four-point sparkle (stationary details).
local function drawSparkle(canvas: ui.Canvas, x: number, y: number, r: number, rgb: number, alpha: number)
	local s = ui.Path({})
	s:moveTo(x, y - r); s:lineTo(x + r * 0.25, y - r * 0.25); s:lineTo(x + r, y); s:lineTo(x + r * 0.25, y + r * 0.25)
	s:lineTo(x, y + r); s:lineTo(x - r * 0.25, y + r * 0.25); s:lineTo(x - r, y); s:lineTo(x - r * 0.25, y - r * 0.25)
	s:close()
	canvas:drawPath(s, paint(rgb, alpha))
end

-- Celestial's drifting, twinkling stars and Star Glitter's glitter, in a
-- 180 x 38 frame stretched to the plate (positions after the preview).
local CELESTIAL = { {12, 11, 6}, {34, 29, 4.5}, {65, 7, 4.5}, {103, 31, 4.5}, {140, 8, 6}, {167, 25, 5} }
local GLITTER = { {5, 8, 2}, {17, 27, 2}, {28, 7, 3}, {39, 31, 1.8}, {51, 9, 2.2}, {65, 28, 3}, {78, 6, 2}, {89, 32, 2.5},
	{102, 8, 1.8}, {114, 27, 2}, {127, 5, 3}, {140, 30, 2}, {154, 9, 2.7}, {172, 25, 3}, {9, 33, 1.4}, {46, 20, 1.4},
	{96, 17, 1.4}, {162, 34, 1.4} }
local CELESTIAL_INK = { 0xfcf3ff, 0xd8b9ff, 0xa4bfff }
local GLITTER_INK = { 0xfff4be, 0xe6ba57, 0xffffff }
-- Leopard rosettes: irregular dark rings with brown centres.
local ROSETTES = { {7, 5, 1, 18}, {32, 25, 0.9, -12}, {58, 6, 1.1, 25}, {84, 26, 1, 10}, {113, 6, 1, -30}, {140, 27, 1.15, -18}, {168, 7, 0.95, 20} }
local SPOTS = { {22, 9}, {47, 19}, {73, 3}, {102, 32}, {128, 19}, {157, 18} }

local function rosette(canvas: ui.Canvas, x: number, y: number, s: number, angle: number)
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(math.rad(angle))
	canvas:scale(s, s)
	local outer = ui.Path({})
	outer:moveTo(-10, -3); outer:quadraticBezierTo(-12, -9, -5, -10); outer:lineTo(0, -8); outer:quadraticBezierTo(7, -12, 11, -6)
	outer:lineTo(8, -1); outer:quadraticBezierTo(12, 6, 5, 9); outer:lineTo(1, 6); outer:quadraticBezierTo(-5, 11, -10, 5)
	outer:lineTo(-7, 1); outer:close()
	canvas:drawPath(outer, paint(0x3b211b))
	local inner = ui.Path({})
	inner:moveTo(-6, -2); inner:quadraticBezierTo(-7, -6, -2, -6); inner:lineTo(1, -4); inner:quadraticBezierTo(6, -7, 7, -3)
	inner:lineTo(5, 0); inner:quadraticBezierTo(7, 5, 2, 5); inner:lineTo(0, 3); inner:quadraticBezierTo(-5, 7, -6, 2)
	inner:lineTo(-4, 0); inner:close()
	canvas:drawPath(inner, paint(0xa46738))
	-- Breaks in the ring, so it reads as a rosette rather than a spot.
	canvas:drawLine(offset(-10, -6), offset(-6, -4), stroke(0xc18c56, 1, 3))
	canvas:drawLine(offset(5, 7), offset(8, 11), stroke(0xc18c56, 1, 3))
	canvas:restore()
end

local function paintArt(art: string, canvas: ui.Canvas, size: ui.Size, t: number, edge: number)
	local sx, sy = size.width / 180, size.height / 38
	if art == "stars" or art == "glitter" then
		local glitter = art == "glitter"
		local points = if glitter then GLITTER else CELESTIAL
		local inks = if glitter then GLITTER_INK else CELESTIAL_INK
		local driftX = if glitter then 0 else math.sin(t * 2 * math.pi / 9) * 2
		local driftY = if glitter then 0 else math.sin(t * 2 * math.pi / 9 + 1) * 1
		local r = math.min(sx, sy)
		for i, s in points do
			local speed = if glitter then 1.5 + (i % 3) * 0.4 else 3 + i % 3
			local wave = 0.5 + 0.5 * math.sin((t + i * 0.37) * 2 * math.pi / speed)
			local alpha = if glitter then 0.35 + 0.65 * wave else 0.55 + 0.45 * wave
			local scale = if glitter then 0.7 + 0.42 * wave else 0.85 + 0.25 * wave
			drawStar(canvas, (s[1] + driftX) * sx, (s[2] + driftY) * sy, s[3] * r * scale, inks[(i - 1) % 3 + 1], alpha,
				math.rad(-10 + 24 * wave))
		end
	elseif art == "leopard" then
		canvas:save()
		canvas:scale(sx, sy)
		for _, s in ROSETTES do rosette(canvas, s[1], s[2], s[3], s[4]) end
		for _, s in SPOTS do canvas:drawCircle(offset(s[1], s[2]), 1.6, paint(0x493022)) end
		canvas:restore()
	elseif art == "sparkles" then
		for _, s in { {14, 9, 3}, {160, 27, 3}, {150, 8, 2}, {28, 29, 2} } do
			drawSparkle(canvas, s[1] * sx, s[2] * sy, s[3] * math.min(sx, sy) * 1.4, 0xfff4ff, 0.9)
		end
	elseif art == "frame" then
		local inset = 3
		canvas:drawRRect(ui.RRect.fromLTRBXY(inset, inset, size.width - inset, size.height - inset, 6, 6), stroke(edge, 0.35, 1))
	end
	if art == "sweep" or art == "glitter" then
		-- A light sweeping across (Star Glitter) or along the gold border (Royal Gold).
		local phase = (t / 3.8) % 1
		local x = -0.4 * size.width + phase * 1.8 * size.width
		local band = ui.Paint({})
		band.shader = p.LinearGradient({colors = { color(0x00fff3b9), color(if art == "sweep" then 0xccfff1c0 else 0x55fff3b9), color(0x00fff3b9) },
			begin = p.Alignment.centerLeft, ["end"] = p.Alignment.centerRight}):createShader({
			rect = ui.Rect.fromLTWH(x - size.width * 0.25, 0, size.width * 0.5, size.height)})
		if art == "sweep" then
			band.style = ui.PaintingStyle.stroke
			band.strokeWidth = 2
			canvas:drawRRect(ui.RRect.fromLTRBXY(1, 1, size.width - 1, size.height - 1, 6, 6), band)
		else
			canvas:drawRect(ui.Rect.fromLTWH(0, 0, size.width, size.height), band)
		end
	end
end

-- Ornaments: a small painted mark before the name, [s] tall.
local function paintOrnament(kind: string, canvas: ui.Canvas, s: number, rgb: number)
	local c = s / 2
	if kind == "heart" then
		local h = ui.Path({})
		h:moveTo(c, s * 0.85)
		h:cubicTo(s * -0.1, s * 0.4, s * 0.15, s * 0.05, c, s * 0.3)
		h:cubicTo(s * 0.85, s * 0.05, s * 1.1, s * 0.4, c, s * 0.85)
		canvas:drawPath(h, stroke(rgb, 1, math.max(1.2, s * 0.12)))
	elseif kind == "crown" then
		local k = ui.Path({})
		k:moveTo(s * 0.08, s * 0.8); k:lineTo(s * 0.08, s * 0.3); k:lineTo(s * 0.32, s * 0.55); k:lineTo(c, s * 0.15)
		k:lineTo(s * 0.68, s * 0.55); k:lineTo(s * 0.92, s * 0.3); k:lineTo(s * 0.92, s * 0.8); k:close()
		canvas:drawPath(k, paint(rgb))
	elseif kind == "moon" then
		canvas:drawCircle(offset(c, c), s * 0.42, paint(rgb))
		canvas:drawCircle(offset(c + s * 0.2, c - s * 0.1), s * 0.36, paint(0x3a2741))
	elseif kind == "flower" then
		for i = 0, 4 do
			local a = i * 2 * math.pi / 5 - math.pi / 2
			canvas:drawCircle(offset(c + math.cos(a) * s * 0.24, c + math.sin(a) * s * 0.24), s * 0.18, paint(rgb))
		end
		canvas:drawCircle(offset(c, c), s * 0.13, paint(0xffe78a))
	elseif kind == "leaf" then
		local l = ui.Path({})
		l:moveTo(s * 0.1, s * 0.9); l:quadraticBezierTo(s * 0.05, s * 0.1, s * 0.9, s * 0.1); l:quadraticBezierTo(s * 0.85, s * 0.9, s * 0.1, s * 0.9)
		canvas:drawPath(l, paint(rgb))
		canvas:drawLine(offset(s * 0.15, s * 0.85), offset(s * 0.7, s * 0.3), stroke(0x355b50, 1, math.max(1, s * 0.08)))
	elseif kind == "mushroom" then
		local cap = ui.Path({})
		cap:moveTo(s * 0.05, s * 0.55); cap:quadraticBezierTo(c, s * -0.15, s * 0.95, s * 0.55); cap:close()
		canvas:drawPath(cap, paint(0xd9564c))
		canvas:drawRRect(ui.RRect.fromLTRBXY(s * 0.36, s * 0.5, s * 0.64, s * 0.95, s * 0.1, s * 0.1), paint(0xf3e5cc))
		canvas:drawCircle(offset(s * 0.32, s * 0.36), s * 0.07, paint(0xfff6ea))
		canvas:drawCircle(offset(s * 0.62, s * 0.28), s * 0.08, paint(0xfff6ea))
	elseif kind == "cloud" then
		canvas:drawCircle(offset(s * 0.32, s * 0.6), s * 0.22, paint(rgb))
		canvas:drawCircle(offset(s * 0.55, s * 0.45), s * 0.28, paint(rgb))
		canvas:drawCircle(offset(s * 0.78, s * 0.62), s * 0.2, paint(rgb))
		canvas:drawRRect(ui.RRect.fromLTRBXY(s * 0.1, s * 0.6, s * 0.95, s * 0.82, s * 0.11, s * 0.11), paint(rgb))
	end
end

export type PlateOptions = { scale: number, minWidth: number?, maxWidth: number?, fill: boolean? }

-- [name] (built by Cosmetics.name) on plate [id] at time [t]; the name alone without one.
function Cosmetics.plate(name: w.Widget, id: string?, t: number, options: PlateOptions): w.Widget
	local plate = Looks.plate(id)
	if not plate then return name end
	local k = options.scale
	local fill = plate.fill
	local gradient = plate.gradient
	local decoration: p.BoxDecoration
	local radius = p.BorderRadius.circular(plate.radius * k)
	local border = p.Border.all({color = opaque(plate.edge), width = (plate.edgeWidth or 1) * (if plate.dotted then 1.6 else 1)})
	local glow = plate.glow
	local shadows = if glow then { p.BoxShadow({color = color(0x55000000 + glow), blurRadius = 8 * k}) } else nil
	if gradient then
		local colors: {ui.Color} = {}
		for i, rgb in gradient do colors[i] = opaque(rgb) end
		local begin, finish = p.Alignment.topLeft, p.Alignment.bottomRight
		if plate.period then
			table.insert(colors, opaque(gradient[1]))
			local shift = -5 * ((t / plate.period) % 1)
			begin, finish = p.Alignment({x = -1 + shift, y = -0.3}), p.Alignment({x = 4 + shift, y = 0.3})
		end
		decoration = p.BoxDecoration({gradient = p.LinearGradient({colors = colors, begin = begin, ["end"] = finish,
			tileMode = if plate.period then ui.TileMode.repeated else ui.TileMode.clamp}), border = border, borderRadius = radius,
			boxShadow = shadows})
	else
		decoration = p.BoxDecoration({color = opaque(fill or 0x594771), border = border, borderRadius = radius, boxShadow = shadows})
	end
	local row: {w.Widget} = {}
	local ornament = plate.ornament
	if ornament then
		local s = 13 * k
		local rgb = plate.ornamentColor or 0xffffff
		table.insert(row, w.SizedBox({width = s, height = s, child = w.CustomPaint({painter = w.CallbackPainter({
			onPaint = function(canvas: ui.Canvas, _: ui.Size) paintOrnament(ornament, canvas, s, rgb) end})})}))
		table.insert(row, w.SizedBox({width = 5 * k}))
	end
	table.insert(row, w.Flexible({child = name}))
	local content: w.Widget = w.Row({mainAxisSize = w.MainAxisSize.min, mainAxisAlignment = w.MainAxisAlignment.center, children = row})
	local art = plate.art
	local layers: {w.Widget} = {}
	if art then
		local edge = plate.edge
		table.insert(layers, w.Positioned.fill({child = w.ClipRRect({borderRadius = radius, child = w.CustomPaint({painter = w.CallbackPainter({
			onPaint = function(canvas: ui.Canvas, size: ui.Size) paintArt(art, canvas, size, t, edge) end})})})}))
	end
	table.insert(layers, w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 11 * k, vertical = 5 * k}), child = content}))
	return w.Container({
		constraints = r.BoxConstraints({minWidth = options.minWidth or 0, maxWidth = options.maxWidth or math.huge,
			minHeight = 26 * k}),
		decoration = decoration,
		child = w.Stack({alignment = p.Alignment.center, children = layers}),
	})
end

-- A whole label: [text] in [names] on [plates], [size] pt, at time [t].
function Cosmetics.label(text: string, names: string?, plates: string?, t: number, size: number, ink: number?, maxWidth: number?): w.Widget
	local plate = Looks.plate(plates)
	local name = Cosmetics.name(text, names, t, { size = size, ink = if plate and plate.ink then plate.ink else ink,
		outline = if plate then plate.outline else nil, soft = plate == nil })
	return Cosmetics.plate(name, plates, t, { scale = size / 14,
		minWidth = if plate then math.min(size * 7, maxWidth or math.huge) else nil, maxWidth = maxWidth })
end

-- Avatar glow ----------------------------------------------------------

-- The outfit's full-body render, [height] tall in a [width] box, with glow
-- [glows] around its silhouette (a tinted, blurred copy behind it); fainter
-- with [reduced] effects.
function Cosmetics.avatar(outfit: {number}?, width: number, height: number, glows: string?, reduced: boolean?): w.Widget
	local body = AvatarImage.body(outfit, width, height)
	local glow = Looks.glow(glows)
	if not glow then return body end
	local sigma = if reduced then 3 else 5
	local halo = w.ImageFiltered({imageFilter = ui.ImageFilter.blur({sigmaX = sigma, sigmaY = sigma}),
		child = w.ColorFiltered({colorFilter = ui.ColorFilter.mode(color((if reduced then 0x99000000 else 0xff000000) + glow), ui.BlendMode.srcIn),
			child = AvatarImage.body(outfit, width, height)})})
	return w.SizedBox({width = width, height = height, child = w.Stack({children = {
		halo,
		-- A second, tighter pass makes the outline read right at the edge.
		if reduced then w.SizedBox.shrink({}) else w.ImageFiltered({imageFilter = ui.ImageFilter.blur({sigmaX = 1.5, sigmaY = 1.5}),
			child = w.ColorFiltered({colorFilter = ui.ColorFilter.mode(color(0xcc000000 + glow), ui.BlendMode.srcIn),
				child = AvatarImage.body(outfit, width, height)})}),
		body,
	}})})
end

-- Animation ------------------------------------------------------------

-- Rebuilds [build] with the time each tick of [frame] (client/Shop's), or
-- once at time 0 when [still].
type AnimatedProps = { read frame: foundation.ChangeNotifier, read clock: () -> number, read still: boolean,
	read build: (t: number) -> w.Widget }
type AnimatedFields = { listener: (() -> ())? }
type AnimatedState = w.State<AnimatedProps, AnimatedFields>
local defineAnimated = w.StatefulWidget.define :: w.StatefulWidgetFactory<AnimatedProps, AnimatedFields>
Cosmetics.Animated = defineAnimated("CosmeticsAnimated", {
	createState = function(): AnimatedFields return { listener = nil } end,
	initState = function(self: AnimatedState)
		local listener = function() if self.mounted and not self.widget.still then self:setState(function() end) end end
		self.listener = listener
		self.widget.frame:addListener(listener)
	end,
	dispose = function(self: AnimatedState)
		if self.listener then self.widget.frame:removeListener(self.listener) end
	end,
	build = function(self: AnimatedState, _: w.BuildContext): w.Widget
		return self.widget.build(if self.widget.still then 0 else self.widget.clock())
	end,
})

return table.freeze(Cosmetics)
