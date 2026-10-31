--!strict
--@client
-- Lucky Shot's drawn art: the pixel clouds (a pale lilac one, a warm gold one
-- with a star, a dark plum storm with a yellow bolt; shape and icon set them
-- apart, not just colour), a wooden slingshot whose band and pebble draw back
-- as it reloads, raindrops and the storm's lightning. Clouds are on the
-- prototype's 76 x 54 grid, the slingshot on a 36 x 52 one. Paths are built
-- once; paints come from Blast Mining's shared paint cache.
local ui = require("@dart/ui")
local MiningArt = require("../blast_mining/Art")
local Rules = require("./Rules")

local Art = {}
Art.paint, Art.stroke, Art.glow = MiningArt.paint, MiningArt.stroke, MiningArt.glow

local function polygon(points: {number}): ui.Path
	local path = ui.Path({})
	path:moveTo(points[1], points[2])
	for k = 3, #points, 2 do path:lineTo(points[k], points[k + 1]) end
	path:close()
	return path
end

local function rect(x: number, y: number, w: number, h: number): ui.Path
	return polygon({ x, y, x + w, y, x + w, y + h, x, y + h })
end

type Shapes = { body: ui.Path, shade: ui.Path, base: ui.Path, eyes: ui.Path, cheeks: ui.Path, mouth: ui.Path,
	bolt: ui.Path, star: ui.Path, frame: ui.Path, handle: ui.Path, drop: ui.Path }
local shapes: Shapes? = nil
local function made(): Shapes
	local s = shapes
	if s then return s end
	local eyes, cheeks = rect(27, 28, 3, 4), rect(22, 33, 7, 2)
	eyes:addPath(rect(47, 28, 3, 4), ui.Offset({dx = 0, dy = 0}))
	cheeks:addPath(rect(48, 33, 7, 2), ui.Offset({dx = 0, dy = 0}))
	local frame = ui.Path({})
	frame:moveTo(7, 5); frame:lineTo(17, 25); frame:lineTo(29, 5)
	local handle = ui.Path({})
	handle:moveTo(17, 25); handle:lineTo(19, 47)
	s = {
		body = polygon({ 11, 42, 7, 42, 7, 38, 3, 38, 3, 26, 7, 26, 7, 21, 17, 21, 17, 13, 22, 13, 22, 8, 37, 8, 37, 13, 42, 13,
			42, 21, 46, 21, 46, 17, 59, 17, 59, 22, 65, 22, 65, 27, 72, 27, 72, 38, 67, 38, 67, 42 }),
		shade = polygon({ 7, 34, 11, 34, 11, 38, 63, 38, 63, 34, 68, 34, 68, 39, 63, 39, 63, 42, 11, 42, 11, 38, 7, 38 }),
		base = rect(12, 42, 50, 5),
		eyes = eyes, cheeks = cheeks, mouth = rect(35, 33.3, 7, 1.5),
		bolt = polygon({ 38, 35, 29, 48, 37, 48, 33, 60, 49, 42, 40, 42, 45, 35 }),
		star = polygon({ 61, 4, 63, 9, 68, 11, 63, 13, 61, 18, 59, 13, 54, 11, 59, 9 }),
		frame = frame, handle = handle,
		drop = polygon({ 0, 0, 4, 0, 4, 5, 2, 7, 0, 5 }),
	}
	shapes = s
	return s
end

type Palette = { body: number, edge: number, shade: number, cheek: number, eye: number, life: number }
local PALETTES: {[Rules.Kind]: Palette} = {
	white = { body = 0xfff6ff, edge = 0xad91c7, shade = 0xdfcbed, cheek = 0xedc6e3, eye = 0xa38ab5, life = 0xa98ac4 },
	gold = { body = 0xfff0c2, edge = 0xcaa66c, shade = 0xedcc92, cheek = 0xf0c996, eye = 0xb38b4d, life = 0xd3ac65 },
	storm = { body = 0x8a779d, edge = 0x5e4b76, shade = 0x6c5883, cheek = 0xaa8bb4, eye = 0xead9f5, life = 0x655078 },
}
Art.DROPS = table.freeze({ white = 0xdceeff, gold = 0xfff2c4, storm = 0xead9f5 } :: {[string]: number})

-- A cloud centred at (x, y), [width] wide; [left] is the 0..1 of its life
-- remaining (a thin bar under it) and [alpha] its opacity.
function Art.cloud(canvas: ui.Canvas, kind: Rules.Kind, x: number, y: number, width: number, left: number, alpha: number)
	local s, c = made(), PALETTES[kind]
	local scale = width / 76
	canvas:save()
	canvas:translate(x - width / 2, y - 54 * scale / 2)
	canvas:scale(scale, scale)
	canvas:save()
	canvas:translate(0, 4)
	canvas:drawPath(s.body, Art.paint(0x7163a6, 0.18 * alpha)) -- a soft drop shadow
	canvas:restore()
	canvas:drawPath(s.base, Art.paint(c.shade, alpha))
	canvas:drawPath(s.body, Art.paint(c.body, alpha))
	canvas:drawPath(s.body, Art.stroke(c.edge, alpha, 1.4))
	canvas:drawPath(s.shade, Art.paint(c.shade, alpha))
	canvas:drawPath(s.eyes, Art.paint(c.eye, alpha))
	canvas:drawPath(s.cheeks, Art.paint(c.cheek, alpha))
	canvas:drawPath(s.mouth, Art.paint(if kind == "storm" then 0x5e4b76 else 0xb79ac5, alpha))
	if kind == "storm" then
		canvas:drawPath(s.bolt, Art.paint(0xffedaa, alpha))
		canvas:drawPath(s.bolt, Art.stroke(0xae8c56, alpha, 0.8))
	elseif kind == "gold" then
		canvas:drawPath(s.star, Art.paint(0xfff6c8, alpha))
		canvas:drawPath(s.star, Art.stroke(0xd2ae71, alpha, 0.6))
	end
	-- The life bar.
	canvas:drawRect(ui.Rect.fromLTWH(23, 49, 30, 2.4), Art.paint(0xfff6ff, 0.7 * alpha))
	canvas:drawRect(ui.Rect.fromLTWH(23, 49, 30 * math.clamp(left, 0, 1), 2.4), Art.paint(c.life, alpha))
	canvas:restore()
end

-- The slingshot with its foot at (x, y), [height] tall, leaning by [angle];
-- [ready] (0..1) draws the band and pebble back as it reloads.
function Art.slingshot(canvas: ui.Canvas, x: number, y: number, height: number, angle: number, ready: number, alpha: number)
	local s = made()
	local scale = height / 52
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(angle)
	canvas:scale(scale, scale)
	canvas:translate(-19, -47)
	local frame = Art.stroke(0x674862, alpha, 7)
	frame.strokeCap = ui.StrokeCap.round
	canvas:drawPath(s.frame, frame)
	local handle = Art.stroke(0xbd936e, alpha, 8)
	handle.strokeCap = ui.StrokeCap.round
	canvas:drawPath(s.handle, handle)
	local pull = 10 + math.clamp(ready, 0, 1) * 12
	local band = ui.Path({})
	band:moveTo(7, 5); band:lineTo(18, pull); band:lineTo(29, 5)
	canvas:drawPath(band, Art.stroke(0xd8b5df, alpha, 2))
	canvas:drawCircle(ui.Offset({dx = 18, dy = pull}), 2.6, Art.paint(0xe8c3a1, alpha * (if ready >= 1 then 1 else 0.45)))
	canvas:restore()
end

-- A raindrop at (x, y), [size] tall.
function Art.drop(canvas: ui.Canvas, x: number, y: number, size: number, color: number, alpha: number)
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(0.2)
	canvas:scale(size / 7, size / 7)
	canvas:drawPath(made().drop, Art.paint(color, alpha))
	canvas:restore()
end

-- The storm's lightning at (x, y), [size] tall.
function Art.lightning(canvas: ui.Canvas, x: number, y: number, size: number, alpha: number)
	local s = made()
	local scale = size / 25
	canvas:save()
	canvas:translate(x, y)
	canvas:scale(scale, scale)
	canvas:translate(-39, -42)
	canvas:drawPath(s.bolt, Art.glow(0xfffde0, 0.8 * alpha, 3))
	canvas:drawPath(s.bolt, Art.paint(0xfff4bd, alpha))
	canvas:drawPath(s.bolt, Art.stroke(0xd6b57c, alpha, 0.8))
	canvas:restore()
end

return table.freeze(Art)
