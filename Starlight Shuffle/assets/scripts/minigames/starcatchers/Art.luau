--!strict
--@client
-- Starcatchers' drawn art, after the reference renderer's flat polygon shapes:
-- the three target kinds (a pale lilac five-point star, a larger warm-gold
-- star, a small constellation of four linked stars), the satellite hazard
-- (a body between two solar panels), the faceted moon platforms and the small
-- thrown hand net (a flat oval hoop with a lavender mesh and a short pale
-- handle). Kinds differ by silhouette and size, not only colour. Paints come
-- from Blast Mining's cache, so a frame only costs its draw calls.
local ui = require("@dart/ui")
local MiningArt = require("../blast_mining/Art")
local Rules = require("./Rules")

local Art = {}
local paint, stroke, glow = MiningArt.paint, MiningArt.stroke, MiningArt.glow
Art.paint, Art.stroke, Art.glow = paint, stroke, glow

local function offset(x: number, y: number): ui.Offset return ui.Offset({dx = x, dy = y}) end

local function poly(canvas: ui.Canvas, points: {number}, rgb: number, alpha: number)
	local path = ui.Path({})
	path:moveTo(points[1], points[2])
	for i = 3, #points, 2 do path:lineTo(points[i], points[i + 1]) end
	path:close()
	canvas:drawPath(path, paint(rgb, alpha))
end

-- A unit five-point star and its lit upper facet, made once.
local starPath: ui.Path? = nil
local facetPath: ui.Path? = nil
local function starShapes(): (ui.Path, ui.Path)
	if not starPath or not facetPath then
		local s, f = ui.Path({}), ui.Path({})
		local points: {{number}} = {}
		for i = 0, 9 do
			local a = i * math.pi / 5 - math.pi / 2
			local r = if i % 2 == 1 then 0.44 else 1
			points[i + 1] = { math.cos(a) * r, math.sin(a) * r }
			if i == 0 then s:moveTo(points[1][1], points[1][2]) else s:lineTo(points[i + 1][1], points[i + 1][2]) end
		end
		s:close()
		f:moveTo(0, 0)
		for i = 1, 3 do f:lineTo(points[i][1], points[i][2]) end
		f:close()
		starPath, facetPath = s, f
	end
	return starPath :: ui.Path, facetPath :: ui.Path
end

-- A five-point star of radius [r] at (x, y), turned by [angle].
function Art.star(canvas: ui.Canvas, x: number, y: number, r: number, rgb: number, alpha: number?, angle: number?)
	local s, f = starShapes()
	local a = alpha or 1
	canvas:save()
	canvas:translate(x, y)
	if angle and angle ~= 0 then canvas:rotate(angle) end
	canvas:scale(r, r)
	canvas:drawPath(s, paint(rgb, a))
	canvas:drawPath(f, paint(0xfff4d7, a))
	canvas:restore()
end

local CONSTELLATION = { { -0.8, 0.2 }, { -0.1, -0.65 }, { 0.7, 0.05 }, { 0.2, 0.7 } }

-- A target of [kind] at (x, y), [size] across its main star.
function Art.target(canvas: ui.Canvas, kind: Rules.Kind, x: number, y: number, size: number, alpha: number?, t: number?)
	local a = alpha or 1
	local turn = math.sin((t or 0) / 1.3) * 0.15
	if kind == "constellation" then
		for i = 2, #CONSTELLATION do
			local p0, p1 = CONSTELLATION[i - 1], CONSTELLATION[i]
			canvas:drawLine(offset(x + p0[1] * size, y + p0[2] * size), offset(x + p1[1] * size, y + p1[2] * size), stroke(0xf2c78f, 0.6 * a, 1))
		end
		for i, p in CONSTELLATION do
			Art.star(canvas, x + p[1] * size, y + p[2] * size, if i == 2 then size * 0.35 else size * 0.21, 0xffe0ad, a, 0.1)
		end
	else
		local gold = kind == "gold"
		canvas:drawCircle(offset(x, y), size * 0.9, glow(if gold then 0xf0c282 else 0xe4c2f9, 0.45 * a, size * 0.45))
		Art.star(canvas, x, y, size, if gold then 0xe9c68e else 0xd9c5e8, a, turn)
	end
end

-- A satellite, [size] across its body; [warn] adds a soft pink halo.
function Art.satellite(canvas: ui.Canvas, x: number, y: number, size: number, t: number, warn: boolean, alpha: number?)
	local a = alpha or 1
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(math.sin(t / 1.8) * 0.09)
	if warn then canvas:drawCircle(offset(0, 0), size * 1.3, glow(0xe0a6bb, 0.55 * a, size * 0.5)) end
	poly(canvas, { -size * 0.28, -size * 0.42, size * 0.28, -size * 0.42, size * 0.4, size * 0.4, -size * 0.3, size * 0.47 }, 0xa598b4, a)
	poly(canvas, { -size * 0.28, -size * 0.42, 0, -size * 0.53, size * 0.28, -size * 0.42, size * 0.1, 0 }, 0xe0d7df, a)
	canvas:drawRect(ui.Rect.fromLTWH(-size * 1.1, -size * 0.3, size * 0.7, size * 0.6), paint(0x675a89, a))
	canvas:drawRect(ui.Rect.fromLTWH(size * 0.45, -size * 0.3, size * 0.7, size * 0.6), paint(0x675a89, a))
	for _, xx in { -size * 0.85, -size * 0.6, size * 0.7, size * 0.95 } do
		canvas:drawLine(offset(xx, -size * 0.3), offset(xx, size * 0.3), stroke(0xc9b7d3, a, 0.6))
	end
	canvas:restore()
end

-- A faceted pale moon platform [w] wide, its top at (x, y); [mine] adds the
-- bright accent ring of your own.
function Art.platform(canvas: ui.Canvas, x: number, y: number, w: number, h: number, mine: boolean, alpha: number?)
	local a = alpha or 1
	canvas:save()
	canvas:translate(x, y)
	poly(canvas, { -w * 0.5, -2, -w * 0.34, h * 0.9, -w * 0.13, h * 1.9, w * 0.12, h * 2.25, w * 0.36, h * 0.8, w * 0.5, -2 }, 0x7e709f, a)
	poly(canvas, { -w * 0.5, -2, -w * 0.13, h * 0.5, -w * 0.13, h * 1.9, -w * 0.34, h * 0.9 }, 0xa99ac0, a)
	poly(canvas, { -w * 0.13, h * 0.5, w * 0.12, h * 2.25, w * 0.36, h * 0.8, w * 0.23, 0 }, 0x9281ad, a)
	poly(canvas, { -w * 0.5, -2, -w * 0.31, -h * 0.38, w * 0.12, -h * 0.47, w * 0.44, -h * 0.2, w * 0.5, -2, w * 0.23, h * 0.35, -w * 0.13, h * 0.5 }, 0xd1c4df, a)
	poly(canvas, { -w * 0.31, -h * 0.38, w * 0.12, -h * 0.47, w * 0.44, -h * 0.2, w * 0.23, h * 0.08, -w * 0.12, h * 0.04 }, 0xe3d9e8, a)
	if mine then
		local ring = ui.Rect.fromCenter({center = offset(0, -2), width = w * 0.68, height = h * 0.54})
		canvas:drawOval(ui.Rect.fromCenter({center = offset(0, -2), width = w * 0.74, height = h * 0.62}), glow(0xdfbaff, 0.5, 6))
		canvas:drawOval(ring, stroke(0xffe4af, 0.75 * a, 1.2))
	end
	canvas:restore()
end

-- The hand net at (x, y), [r] its hoop's half-width, turned by [angle]: lit
-- gold when it carries a star, crossed out and pink when tangled.
function Art.net(canvas: ui.Canvas, x: number, y: number, r: number, angle: number, carrying: boolean, tangled: boolean, alpha: number?)
	local a = alpha or 1
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(angle)
	local k = r / 14
	canvas:scale(k, k)
	local width, center = 14, -5
	local ry = width * 0.73
	-- The short handle meets the hand at rest; no cord, no pouch.
	poly(canvas, { -2, 3, 2, 3, 2.5, 24, -2.5, 24 }, 0xa98c90, a)
	poly(canvas, { -1.5, 3, 0.2, 3, 0.8, 23, -1.8, 23 }, 0xebd6b7, a)
	canvas:drawRect(ui.Rect.fromLTWH(-3, 19, 6, 3), paint(0xc8a6c7, a))
	local hoop = ui.Rect.fromCenter({center = offset(0, center), width = width * 2, height = ry * 2})
	canvas:save()
	local clip = ui.Path({})
	clip:addOval(hoop)
	canvas:clipPath({path = clip})
	canvas:drawRect(hoop, paint(if carrying then 0xf9dfac else 0xe9dcf2, if carrying then 0.1 * a else 0.05 * a))
	local mesh = stroke(if tangled then 0xc997b0 else 0xd8c4df, 0.6 * a, 0.65)
	local i = -width * 2
	while i < width * 2 do
		canvas:drawLine(offset(i, center - ry), offset(i + width, center + ry), mesh)
		canvas:drawLine(offset(i, center + ry), offset(i + width, center - ry), mesh)
		i += 4.5
	end
	canvas:restore()
	canvas:drawOval(hoop, stroke(if tangled then 0xd69fb6 elseif carrying then 0xffe3aa else 0xf0e3d4, a, 1.8))
	canvas:drawOval(ui.Rect.fromCenter({center = offset(0, center), width = (width - 1.5) * 2, height = (ry - 1.4) * 2}), stroke(0xb49bbb, 0.67 * a, 0.6))
	if tangled then
		local cross = stroke(0xe4a3bc, a, 1.2)
		canvas:drawLine(offset(-8, center - 6), offset(8, center + 6), cross)
		canvas:drawLine(offset(8, center - 6), offset(-8, center + 6), cross)
	end
	canvas:restore()
end

-- The small white marker over your avatar.
function Art.marker(canvas: ui.Canvas, x: number, y: number)
	poly(canvas, { x - 4, y, x + 4, y, x, y + 7 }, 0xfff0d7, 1)
end

return table.freeze(Art)
