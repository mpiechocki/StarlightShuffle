--!strict
--@client
-- Blast Mining's drawn art: four deliberately simple low-poly sprites (the
-- pickaxe, a gem-flecked rock, a pure gem and a bomb), each a handful of broad
-- flat faces in a restrained palette, and the small effects. Shapes are on a
-- 64 x 64 grid centred on (32, 32). Paths and paints are built once and reused
-- every frame, so a frame only costs its draw calls.
local ui = require("@dart/ui")

export type Sprite = "pickaxe" | "rock" | "gem" | "bomb"
type Face = { points: {number}, color: number }

local FACES: {[Sprite]: {Face}} = {
	-- A short pale timber handle, a softly shaded steel head, a lavender socket.
	pickaxe = {
		{ points = { 30, 17, 35, 17, 36, 57, 31, 59 }, color = 0xa98679 },
		{ points = { 30, 17, 32, 18, 33, 57, 31, 59 }, color = 0xe1c5a4 },
		{ points = { 33, 19, 35, 17, 36, 57, 33, 57 }, color = 0xbfa08a },
		{ points = { 30, 46, 36, 46, 36, 53, 31, 54 }, color = 0x947782 },
		{ points = { 12, 13, 23, 7, 41, 8, 51, 14, 56, 25, 47, 19, 37, 16, 24, 15, 8, 23 }, color = 0x9b94ad },
		{ points = { 12, 13, 23, 7, 41, 8, 51, 14, 37, 12, 23, 11 }, color = 0xe1dce6 },
		{ points = { 12, 13, 23, 11, 37, 12, 37, 16, 24, 15, 8, 23 }, color = 0xc3bdcf },
		{ points = { 37, 12, 51, 14, 56, 25, 47, 19, 37, 16 }, color = 0x807890 },
		{ points = { 29, 10, 36, 11, 36, 19, 30, 19 }, color = 0xaa97bd },
		{ points = { 29, 10, 32, 9, 36, 11, 30, 12 }, color = 0xd9c9e7 },
	},
	-- Mostly matte stone in five broad faces, with three tiny gem chips.
	rock = {
		{ points = { 12, 22, 23, 12, 43, 15, 53, 31, 45, 49, 26, 53, 11, 40 }, color = 0x9e93ad },
		{ points = { 12, 22, 23, 12, 43, 15, 30, 29 }, color = 0xc5bace },
		{ points = { 12, 22, 30, 29, 26, 53, 11, 40 }, color = 0xafa3bd },
		{ points = { 30, 29, 43, 15, 53, 31, 45, 49 }, color = 0x82778f },
		{ points = { 30, 29, 45, 49, 26, 53 }, color = 0x93859f },
		{ points = { 17, 27, 20, 23, 23, 26, 21, 30 }, color = 0xd4b1e9 },
		{ points = { 36, 34, 39, 30, 42, 33, 40, 37 }, color = 0xb7d2e1 },
		{ points = { 25, 43, 28, 39, 31, 42, 29, 46 }, color = 0xcda3df },
	},
	-- A clear amethyst cut from six broad faces.
	gem = {
		{ points = { 19, 16, 37, 9, 49, 26, 39, 50, 26, 56, 13, 34 }, color = 0xbda2d6 },
		{ points = { 19, 16, 37, 9, 32, 27 }, color = 0xeadcf2 },
		{ points = { 37, 9, 49, 26, 32, 27 }, color = 0xcdb9e4 },
		{ points = { 19, 16, 32, 27, 13, 34 }, color = 0xd7c4e9 },
		{ points = { 13, 34, 32, 27, 26, 56 }, color = 0xb796d0 },
		{ points = { 32, 27, 49, 26, 39, 50, 26, 56 }, color = 0x9674b5 },
		{ points = { 32, 27, 39, 50, 26, 56 }, color = 0xbfa0d5 },
	},
	-- A squat faceted charcoal-plum sphere, brass neck, short fuse, one spark.
	bomb = {
		{ points = { 23, 21, 37, 20, 47, 29, 49, 41, 40, 51, 26, 54, 15, 45, 13, 33 }, color = 0x484052 },
		{ points = { 23, 21, 37, 20, 47, 29, 30, 33, 13, 33 }, color = 0x6c5d70 },
		{ points = { 13, 33, 30, 33, 26, 54, 15, 45 }, color = 0x514657 },
		{ points = { 30, 33, 47, 29, 49, 41, 40, 51, 26, 54 }, color = 0x393342 },
		{ points = { 21, 24, 27, 22, 25, 29, 19, 32 }, color = 0x9a8490 },
		{ points = { 27, 17, 35, 16, 37, 22, 26, 24 }, color = 0xb69a67 },
		{ points = { 27, 17, 34, 16, 35, 19, 27, 20 }, color = 0xe4cb91 },
		{ points = { 30, 17, 29, 11, 33, 7, 41, 8, 43, 12, 40, 13, 38, 10, 34, 10, 33, 13, 33, 17 }, color = 0xad9269 },
		{ points = { 42, 7, 44, 10, 48, 10, 45, 13, 45, 17, 42, 14, 38, 14, 41, 11 }, color = 0xffe6a0 },
	},
}

local Art = {}

-- Paints by ARGB, made once.
local paints: {[number]: ui.Paint} = {}
local function argb(color: number, alpha: number): number
	return math.floor(math.clamp(alpha, 0, 1) * 255 + 0.5) * 0x1000000 + color
end

function Art.paint(color: number, alpha: number?): ui.Paint
	local key = argb(color, alpha or 1)
	local paint = paints[key]
	if not paint then
		paint = ui.Paint({})
		paint.color = ui.Color({value = key})
		paint.isAntiAlias = true
		paints[key] = paint
	end
	return paint
end

-- Stroked paints (rings), by ARGB and width.
local strokes: {[string]: ui.Paint} = {}
function Art.stroke(color: number, alpha: number, width: number): ui.Paint
	local key = argb(color, alpha) .. ":" .. width
	local paint = strokes[key]
	if not paint then
		paint = ui.Paint({})
		paint.color = ui.Color({value = argb(color, alpha)})
		paint.style = ui.PaintingStyle.stroke
		paint.strokeWidth = width
		paint.isAntiAlias = true
		strokes[key] = paint
	end
	return paint
end

-- Soft glows: a blurred fill.
local glows: {[string]: ui.Paint} = {}
function Art.glow(color: number, alpha: number, sigma: number): ui.Paint
	local key = argb(color, alpha) .. ":" .. sigma
	local paint = glows[key]
	if not paint then
		paint = ui.Paint({})
		paint.color = ui.Color({value = argb(color, alpha)})
		paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma)
		glows[key] = paint
	end
	return paint
end

local paths: {[Sprite]: {ui.Path}} = {}
local function facesOf(sprite: Sprite): {ui.Path}
	local made = paths[sprite]
	if made then return made end
	made = {}
	for i, face in FACES[sprite] do
		local path = ui.Path({})
		local p = face.points
		path:moveTo(p[1], p[2])
		for k = 3, #p, 2 do path:lineTo(p[k], p[k + 1]) end
		path:close()
		made[i] = path
	end
	paths[sprite] = made
	return made
end

-- Draws [sprite] centred at (x, y), [size] wide, turned by [angle] radians.
function Art.sprite(canvas: ui.Canvas, sprite: Sprite, x: number, y: number, size: number, angle: number?, alpha: number?)
	local faces = facesOf(sprite)
	canvas:save()
	canvas:translate(x, y)
	if angle and angle ~= 0 then canvas:rotate(angle) end
	canvas:scale(size / 64, size / 64)
	canvas:translate(-32, -32)
	for i, face in FACES[sprite] do canvas:drawPath(faces[i], Art.paint(face.color, alpha)) end
	canvas:restore()
end

-- A chip: a small shard for hit bursts, drawn like a sprite face.
local chipPath: ui.Path? = nil
function Art.chip(canvas: ui.Canvas, x: number, y: number, size: number, angle: number, color: number, alpha: number)
	local path = chipPath
	if not path then
		path = ui.Path({})
		path:moveTo(-1, -1); path:lineTo(1, -0.6); path:lineTo(0.2, 1); path:close()
		chipPath = path
	end
	canvas:save()
	canvas:translate(x, y)
	canvas:rotate(angle)
	canvas:scale(size, size)
	canvas:drawPath(path :: ui.Path, Art.paint(color, alpha))
	canvas:restore()
end

-- The marker over the local player: a small white downward chevron.
local markerPath: ui.Path? = nil
function Art.marker(canvas: ui.Canvas, x: number, y: number)
	local path = markerPath
	if not path then
		path = ui.Path({})
		path:moveTo(-6, -3); path:lineTo(6, -3); path:lineTo(0, 5); path:close()
		markerPath = path
	end
	canvas:save()
	canvas:translate(x, y)
	canvas:drawPath(path :: ui.Path, Art.glow(0xe6bcff, 0.9, 4))
	canvas:drawPath(path :: ui.Path, Art.paint(0xfff7ff))
	canvas:restore()
end

-- The colours chips take from each item.
Art.CHIPS = table.freeze({ rock = { 0xc5bace, 0x9e93ad, 0xd4b1e9 }, gem = { 0xeadcf2, 0xbda2d6, 0x9674b5 },
	bomb = { 0xffe6a0, 0xffc76d, 0x6c5d70 } } :: {[string]: {number}})

return table.freeze(Art)
