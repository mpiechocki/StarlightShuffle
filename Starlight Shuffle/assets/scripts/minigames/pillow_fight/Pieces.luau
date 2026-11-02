--!strict
--@client
-- Pillow Fight's shared pieces: everyone's picture (a human's own outfit
-- through the platform's avatar render; a bot's labelled doll artwork), the
-- red "!" danger badge, and the faces of the Throw and Dodge controls. The
-- how-to examples draw these same pieces, so they look exactly like play.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local game = require("@moonbase/game")
local engine = require("@moonbase/engine")
local Rules = require("./Rules")
local Assets = require("./Assets")
local Art = require("./Art")
local AvatarImage = require("../../widgets/AvatarImage")
local GameUi = require("../../widgets/GameUi")

local function color(v: number): ui.Color return ui.Color({value = v}) end

local Pieces = {}

-- A painted layer filling its box, drawn by [onPaint] each time it builds.
function Pieces.paint(onPaint: (canvas: ui.Canvas, size: ui.Size) -> ()): w.Widget
	return w.CustomPaint({painter = w.CallbackPainter({onPaint = onPaint})})
end

local function doll(pt: Rules.Participant): engine.Texture?
	local dolls = Assets.get().dolls
	local texture = if pt.doll then dolls[pt.doll] else nil
	return if texture and texture.isValid then texture else nil
end

-- Pictures are kept by participant and size: the same widget each frame, so
-- an avatar loads once and frame rebuilds stop at it.
local bodies: {[string]: w.Widget} = {}
local count = 0

-- The full body, [height] tall, standing on the bottom of a [width] box.
function Pieces.body(pt: Rules.Participant?, width: number, height: number): w.Widget
	if not pt then return w.SizedBox({width = width, height = height}) end
	local texture = if pt.bot then doll(pt) else nil
	local key = pt.id .. ":" .. math.floor(width) .. ":" .. math.floor(height) .. (if texture then ":d" else "")
	local made = bodies[key]
	if made then return made end
	if count > 96 then table.clear(bodies); count = 0 end
	if pt.bot then
		made = if texture then w.Image({image = game.image(texture), width = width, height = height, fit = p.BoxFit.contain,
			alignment = p.Alignment.bottomCenter, filterQuality = ui.FilterQuality.medium}) else AvatarImage.body(nil, width, height)
	else
		made = AvatarImage.body(pt.outfit, width, height)
	end
	bodies[key] = made :: w.Widget
	count += 1
	return made :: w.Widget
end

-- The head and hair, [size] square, in a small rounded frame.
function Pieces.head(pt: Rules.Participant?, size: number): w.Widget
	local texture = if pt and pt.bot then doll(pt) else nil
	local picture: w.Widget
	if texture then
		local wide = size * 1.42
		picture = w.ClipRect({child = w.SizedBox({width = size, height = size, child = w.OverflowBox({
			alignment = p.Alignment.topCenter, minWidth = wide, maxWidth = wide, minHeight = 0, maxHeight = size * 4,
			child = w.Image({image = game.image(texture), width = wide, fit = p.BoxFit.fitWidth, alignment = p.Alignment.topCenter}),
		})})})
	else
		picture = AvatarImage.head(if pt then pt.outfit else nil, size)
	end
	return GameUi.portrait(picture)
end

-- The red circular "!" over your avatar while a pillow is about to land on you.
function Pieces.badge(size: number): w.Widget
	return w.Container({width = size, height = size, decoration = p.BoxDecoration({color = color(0xffc83f65), shape = p.BoxShape.circle,
		border = p.Border.all({color = color(0xffffe1c9), width = 2}),
		boxShadow = {p.BoxShadow({color = color(0x66ed7f98), blurRadius = 16})}}),
		child = w.Center({child = w.Text({data = "!", style = GameUi.style(size * 0.7, color(0xfffff8ec), ui.FontWeight.w900)})})})
end

local swoosh: ui.Path? = nil
local function paintSwoosh(canvas: ui.Canvas, x: number, y: number, size: number, rgb: number)
	local path = swoosh
	if not path then
		path = ui.Path({})
		path:moveTo(-0.5, 0.02)
		path:quadraticBezierTo(-0.36, -0.26, -0.2, 0.02)
		path:quadraticBezierTo(-0.04, 0.28, 0.12, 0.02)
		path:lineTo(0.46, 0.02)
		path:moveTo(0.3, -0.14); path:lineTo(0.46, 0.02); path:lineTo(0.3, 0.18)
		swoosh = path
	end
	canvas:save()
	canvas:translate(x, y)
	canvas:scale(size, size)
	canvas:drawPath(path :: ui.Path, Art.stroke(rgb, 1, 0.09))
	canvas:restore()
end

export type ThrowFace = { width: number, height: number, charge: number, enabled: boolean, ready: boolean }

-- The Throw control's face: the pillow, THROW and the charge bar.
function Pieces.throwFace(f: ThrowFace): w.Widget
	local full = f.charge >= 1
	return w.Opacity({opacity = if f.enabled then 1 else 0.48, child = w.Container({width = f.width, height = f.height,
		decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(15),
			gradient = p.LinearGradient({begin = p.Alignment.topLeft, ["end"] = p.Alignment.bottomRight,
				colors = { color(0xff765274), color(0xff563c69) }}),
			border = p.Border.all({color = color(0xffffe1ac), width = if f.ready then 2 else 1}),
			boxShadow = if f.ready then {p.BoxShadow({color = color(0x55ffe9a9), blurRadius = 10})} else nil}),
		child = w.Column({mainAxisAlignment = w.MainAxisAlignment.center, children = {
			w.SizedBox({width = 46, height = math.min(34, f.height * 0.36), child = Pieces.paint(function(canvas: ui.Canvas, size: ui.Size)
				Art.pillow(canvas, size.width / 2, size.height / 2, math.min(size.width, size.height * 1.33), -0.12 * f.charge)
			end)}),
			w.SizedBox({height = 4}),
			w.Text({data = "THROW", style = GameUi.style(12, GameUi.TEXT, ui.FontWeight.w900, 0.9)}),
			w.SizedBox({height = 6}),
			w.ClipRRect({borderRadius = p.BorderRadius.circular(3), child = w.Container({width = math.min(150, f.width * 0.6), height = 6,
				color = color(0x6659406c), alignment = p.Alignment.centerLeft, child = w.FractionallySizedBox({widthFactor = math.clamp(f.charge, 0, 1),
					child = w.Container({color = color(if full then 0xffffe9a9 else 0xffffe4a7)})})})}),
		}}),
	})})
end

export type DodgeFace = { width: number, height: number, enabled: boolean, danger: boolean, active: boolean, refill: number }

-- The Dodge control's face: the swoosh and DODGE; lit red while a pillow is
-- about to land on you, cyan during your dodge, refilling while it cools down.
function Pieces.dodgeFace(f: DodgeFace): w.Widget
	local lit = f.danger and f.enabled
	return w.Opacity({opacity = if f.enabled or f.active then 1 else 0.55, child = w.Container({width = f.width, height = f.height,
		decoration = p.BoxDecoration({color = color(if lit then 0xffad3e62 else 0xee4b335e), borderRadius = p.BorderRadius.circular(15),
			border = p.Border.all({color = color(if f.active then 0xffc6fffa elseif lit then 0xffffe9a9 else 0xffc4a6cf),
				width = if lit or f.active then 2 else 1}),
			boxShadow = if lit then {p.BoxShadow({color = color(0x88ff8a96), blurRadius = 14})}
				elseif f.active then {p.BoxShadow({color = color(0x88c6fffa), blurRadius = 12})} else nil}),
		child = w.ClipRRect({borderRadius = p.BorderRadius.circular(14), child = w.Stack({children = {
			-- The refill: rises from the bottom as Dodge comes back.
			w.Positioned({left = 0, right = 0, bottom = 0, height = f.height * (if f.enabled then 0 else math.clamp(f.refill, 0, 1)),
				child = w.Container({color = color(0x33ffffff)})}),
			w.Positioned({left = 0, right = 0, top = 0, bottom = 0, child = w.Column({mainAxisAlignment = w.MainAxisAlignment.center, children = {
				w.SizedBox({width = 40, height = 22, child = Pieces.paint(function(canvas: ui.Canvas, size: ui.Size)
					paintSwoosh(canvas, size.width / 2, size.height / 2, if lit then 34 else 30, if f.active then 0xc6fffa else 0xffedce)
				end)}),
				w.SizedBox({height = 6}),
				w.Text({data = "DODGE", style = GameUi.style(11, GameUi.TEXT, ui.FontWeight.w900, 0.8)}),
			}})}),
		}})}),
	})})
end

return table.freeze(Pieces)
