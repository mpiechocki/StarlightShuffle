--!strict
--@client
-- Pillow Fight's drawn art: the approved plump stitched pillow (the paths of
-- art/pillow_fight/pillow.svg, on its 128 x 96 grid: soft ivory-to-lilac
-- fill, mauve outline, white piping, a shine and four corner stitches), used
-- for held and flying pillows, the Throw button and the how-to examples; and
-- the small marks around the avatars (hearts, floor rings, the target chevron,
-- feathers). Paths, paints and the gradient are made once and reused.
local ui = require("@dart/ui")
local p = require("@flutter/painting")
local MiningArt = require("../blast_mining/Art")

local Art = {}
Art.paint, Art.stroke, Art.glow = MiningArt.paint, MiningArt.stroke, MiningArt.glow

local function color(v: number): ui.Color return ui.Color({value = v}) end

type Pillow = { outline: ui.Path, piping: ui.Path, stitches: ui.Path, fill: ui.Paint, faded: {[number]: ui.Paint} }
-- A soft blurred outline (screen-edge glows), by ARGB, width and blur.
local edges: {[string]: ui.Paint} = {}
function Art.edge(rgb: number, alpha: number, width: number, sigma: number): ui.Paint
	local key = rgb .. ":" .. math.floor(alpha * 100) .. ":" .. width .. ":" .. sigma
	local paint = edges[key]
	if not paint then
		paint = ui.Paint({})
		paint.color = ui.Color({value = math.floor(math.clamp(alpha, 0, 1) * 255 + 0.5) * 0x1000000 + rgb})
		paint.style = ui.PaintingStyle.stroke
		paint.strokeWidth = width
		paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma)
		edges[key] = paint
	end
	return paint
end

local pillow: Pillow? = nil

local function curve(path: ui.Path, points: {number})
	path:moveTo(points[1], points[2])
	for i = 3, #points, 6 do path:cubicTo(points[i], points[i + 1], points[i + 2], points[i + 3], points[i + 4], points[i + 5]) end
	path:close()
end

local function made(): Pillow
	local done = pillow
	if done then return done end
	local outline, piping, stitches = ui.Path({}), ui.Path({}), ui.Path({})
	curve(outline, { 12, 12, 28, 15, 42, 8, 64, 10, 86, 8, 100, 15, 116, 12, 111, 26, 119, 34, 117, 48, 119, 62, 111, 70, 116, 84,
		100, 81, 86, 88, 64, 86, 42, 88, 28, 81, 12, 84, 17, 70, 9, 62, 11, 48, 9, 34, 17, 26, 12, 12 })
	curve(piping, { 20, 20, 39, 23, 48, 17, 64, 18, 80, 17, 92, 23, 108, 20, 104, 32, 111, 41, 109, 49, 111, 58, 104, 68, 108, 76,
		89, 73, 79, 80, 64, 78, 48, 80, 36, 73, 20, 76, 24, 64, 17, 57, 19, 48, 17, 36, 24, 29, 20, 20 })
	for _, s in { { 14, 15, 27, 26 }, { 113, 15, 101, 26 }, { 14, 81, 26, 70 }, { 113, 81, 101, 70 } } do
		stitches:moveTo(s[1], s[2]); stitches:lineTo(s[3], s[4])
	end
	local fill = ui.Paint({})
	fill.isAntiAlias = true
	fill.shader = p.LinearGradient({begin = p.Alignment.topLeft, ["end"] = p.Alignment({x = -0.2, y = 1}),
		colors = { color(0xfffffaf1), color(0xfff4e8ef), color(0xffd5b9d8) }, stops = { 0, 0.55, 1 }})
		:createShader({rect = ui.Rect.fromLTWH(10, 8, 110, 82)})
	done = { outline = outline, piping = piping, stitches = stitches, fill = fill, faded = {} }
	pillow = done
	return done
end

-- The pillow's fill at [alpha] (the gradient, made once per alpha step).
local function fillAt(art: Pillow, alpha: number): ui.Paint
	if alpha >= 1 then return art.fill end
	local key = math.floor(alpha * 20 + 0.5)
	local paint = art.faded[key]
	if not paint then
		paint = ui.Paint({})
		paint.isAntiAlias = true
		paint.shader = art.fill.shader
		paint.color = color(math.floor(key / 20 * 255) * 0x1000000)
		art.faded[key] = paint
	end
	return paint
end

-- The pillow centred at (x, y), [width] wide, turned by [angle] radians; a
-- soft [glow] (RGB) behind it marks your own or an incoming pillow.
function Art.pillow(canvas: ui.Canvas, x: number, y: number, width: number, angle: number?, alpha: number?, glow: number?)
	local art = made()
	local a = alpha or 1
	canvas:save()
	canvas:translate(x, y)
	if angle and angle ~= 0 then canvas:rotate(angle) end
	canvas:scale(width / 128, width / 128)
	canvas:translate(-64, -48)
	if glow then
		canvas:drawPath(art.outline, Art.glow(glow, 0.75 * a, 7))
	end
	canvas:save()
	canvas:translate(0, 3)
	canvas:drawPath(art.outline, Art.glow(0x725776, 0.27 * a, 3))
	canvas:restore()
	canvas:drawPath(art.outline, fillAt(art, a))
	canvas:drawOval(ui.Rect.fromLTWH(19, 14, 86, 46), Art.glow(0xfffdf7, 0.5 * a, 8))
	canvas:drawPath(art.outline, Art.stroke(0xaa8cac, a, 2.5))
	canvas:drawPath(art.piping, Art.stroke(0xfff8f2, a, 2))
	canvas:drawPath(art.stitches, Art.stroke(0xc5a7c7, a, 1.5))
	canvas:restore()
end

local heart: ui.Path? = nil
-- A heart [size] tall centred at (x, y): filled ivory, or an empty outline.
function Art.heart(canvas: ui.Canvas, x: number, y: number, size: number, full: boolean, alpha: number?)
	local path = heart
	if not path then
		path = ui.Path({})
		path:moveTo(0, 0.42)
		path:cubicTo(-0.62, 0.02, -0.5, -0.5, 0, -0.2)
		path:cubicTo(0.5, -0.5, 0.62, 0.02, 0, 0.42)
		path:close()
		heart = path
	end
	local a = alpha or 1
	canvas:save()
	canvas:translate(x, y)
	canvas:scale(size, size)
	if full then
		canvas:drawPath(path :: ui.Path, Art.paint(0xfff2dd, a))
		canvas:drawPath(path :: ui.Path, Art.stroke(0x8a5f8c, a, 0.09))
	else
		canvas:drawPath(path :: ui.Path, Art.paint(0x5b3b68, 0.45 * a))
		canvas:drawPath(path :: ui.Path, Art.stroke(0xfff2dd, 0.8 * a, 0.09))
	end
	canvas:restore()
end

-- [hp] of [max] hearts in a row centred at (x, y).
function Art.hearts(canvas: ui.Canvas, x: number, y: number, size: number, hp: number, max: number, alpha: number?)
	local gap = size * 1.15
	local left = x - gap * (max - 1) / 2
	for i = 1, max do Art.heart(canvas, left + (i - 1) * gap, y, size, i <= hp, alpha) end
end

-- An oval floor ring centred at (x, y): a soft fill, an optional outline and glow.
function Art.ring(canvas: ui.Canvas, x: number, y: number, w: number, h: number, fill: number, fillAlpha: number,
	edge: number?, glow: number?)
	local rect = ui.Rect.fromLTWH(x - w / 2, y - h / 2, w, h)
	if glow then canvas:drawOval(rect, Art.glow(glow, 0.7, 7)) end
	canvas:drawOval(rect, Art.paint(fill, fillAlpha))
	if edge then canvas:drawOval(rect, Art.stroke(edge, 1, 2)) end
end

-- The charge meter around a floor ring: [fraction] of the oval, from the top.
function Art.charge(canvas: ui.Canvas, x: number, y: number, w: number, h: number, fraction: number)
	local rect = ui.Rect.fromLTWH(x - w / 2, y - h / 2, w, h)
	canvas:drawOval(rect, Art.stroke(0x59406c, 0.55, 4))
	if fraction > 0 then
		canvas:drawArc(rect, -math.pi / 2, fraction * 2 * math.pi, false, Art.stroke(if fraction >= 1 then 0xffe9a9 else 0xffda84, 1, 4))
	end
end

local chevron: ui.Path? = nil
-- The small target chevron above a rival's head, [size] wide.
function Art.chevron(canvas: ui.Canvas, x: number, y: number, size: number)
	local path = chevron
	if not path then
		path = ui.Path({})
		path:moveTo(-0.5, -0.25); path:lineTo(0, 0.25); path:lineTo(0.5, -0.25)
		chevron = path
	end
	canvas:save()
	canvas:translate(x, y)
	canvas:scale(size, size)
	canvas:drawPath(path :: ui.Path, Art.stroke(0x5d4268, 0.5, 0.34))
	canvas:drawPath(path :: ui.Path, Art.stroke(0xfff3bf, 1, 0.2))
	canvas:restore()
end

local feather: ui.Path? = nil
-- A small feather from a pillow hit.
function Art.feather(canvas: ui.Canvas, x: number, y: number, angle: number, alpha: number)
	local path = feather
	if not path then
		path = ui.Path({})
		path:moveTo(0, -9)
		path:quadraticBezierTo(6, -2, 0, 9)
		path:quadraticBezierTo(-6, 2, 0, -9)
		path:close()
		feather = path
	end
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(angle)
	canvas:drawPath(path :: ui.Path, Art.paint(0xfff0e5, alpha))
	canvas:drawPath(path :: ui.Path, Art.stroke(0xc8a7cb, alpha, 1))
	canvas:restore()
end

return table.freeze(Art)
