--!strict
--@client
-- How each shop cosmetic (shared/Shop) looks, as data the widgets draw from
-- (widgets/Cosmetics) and the avatars' aura uses (client/Multiplayer). Colours
-- are 0xRRGGBB. A name is a static colour, or a gradient that flows along the
-- text (animated ones) with an optional glow; a plate is a fill (or a
-- gradient), an edge, a corner shape, a painted ornament before the name and,
-- for some, painted art (stars, glitter, rosettes); a glow is one colour.
local foundation = require("@flutter/foundation")
local Shop = require("../shared/Shop")

local Looks = {}

export type Name = {
	color: number?, -- static colour; nil: the gradient (or the default ink)
	gradient: {number}?, -- colours, looping
	period: number?, -- seconds for one loop of the gradient
	shine: boolean?, -- a bright highlight sweeping across
	glow: number?, -- a soft glow behind the letters
}
export type Plate = {
	fill: number?, gradient: {number}?, period: number?, -- a flowing gradient when animated
	edge: number, edgeWidth: number?, radius: number, dotted: boolean?,
	ink: number?, -- the default name's colour on it (a light plate wants dark letters)
	outline: number, -- the letters' outline, for contrast whatever their colour
	ornament: ("cloud" | "flower" | "mushroom" | "moon" | "leaf" | "heart" | "crown")?, ornamentColor: number?,
	art: ("stars" | "glitter" | "leopard" | "sparkles" | "frame" | "sweep" | "moon")?,
	glow: number?, -- an inner glow
}

Looks.NAMES = table.freeze({
	["name-yellow"] = { color = 0xffe078 }, ["name-blue"] = { color = 0x8daaff }, ["name-cyan"] = { color = 0x66ddff },
	["name-green"] = { color = 0x7fe3a1 }, ["name-orange"] = { color = 0xffb26b }, ["name-red"] = { color = 0xff818d },
	["name-mint"] = { color = 0xa1f2d2 }, ["name-pink"] = { color = 0xff99d5 }, ["name-purple"] = { color = 0xc5a0ff },
	["name-gold"] = { color = 0xe9c46a }, ["name-rose-quartz"] = { color = 0xf3c4da },
	["name-pastel"] = { gradient = { 0xfac6e3, 0xd4c8ff, 0xbce7e6 }, period = 7 },
	["name-rainbow"] = { gradient = { 0xff98ce, 0xffe789, 0x9fefbd, 0x8addff, 0xc0a3ff }, period = 5 },
	["name-shimmer"] = { gradient = { 0xe0ac49, 0xfff6c6, 0xd2a243, 0xfff0ba }, period = 4, shine = true },
	["name-galaxy"] = { gradient = { 0xb7a2ff, 0x8fc3ff, 0xec99d5 }, period = 6 },
	["name-diamond"] = { gradient = { 0xbed5f3, 0xffffff, 0xbde8ff, 0xffffff }, period = 5, shine = true },
	["name-aurora"] = { gradient = { 0xf8c9ff, 0x92fff0, 0xfff2a6, 0xb4b3ff, 0xffb4e1 }, period = 4, glow = 0xdac2ff },
} :: {[string]: Name})

Looks.PLATES = table.freeze({
	["plate-cloud"] = { fill = 0xd4d9ec, edge = 0xffffff, radius = 22, ink = 0x343651, outline = 0xffffff, ornament = "cloud", ornamentColor = 0xffffff },
	["plate-bubble"] = { fill = 0xeab3d8, edge = 0xffddf5, radius = 18, ink = 0x48213e, outline = 0xffe9f6 },
	["plate-flower"] = { fill = 0x6e4165, edge = 0xf2c5e3, edgeWidth = 2, dotted = true, radius = 8, outline = 0x291f3b,
		ornament = "flower", ornamentColor = 0xffd0e7 },
	["plate-mushroom"] = { fill = 0x695342, edge = 0xb69a75, radius = 8, outline = 0x291f3b, ornament = "mushroom" },
	["plate-leopard"] = { fill = 0xc18c56, edge = 0xdcb27f, radius = 8, ink = 0xfff6e5, outline = 0x2b170f, art = "leopard" },
	["plate-midnight"] = { gradient = { 0x251a37, 0x583951, 0x261c38 }, edge = 0xb995b8, radius = 9, outline = 0x1a1226,
		ornament = "moon", ornamentColor = 0xe6bfd9, art = "frame" },
	["plate-garden"] = { fill = 0x355b50, edge = 0xb5d2a0, dotted = true, radius = 8, outline = 0x16261f,
		ornament = "leaf", ornamentColor = 0xd8eea8 },
	["plate-hearts"] = { fill = 0x764b70, edge = 0xdf9ec8, radius = 8, outline = 0x291f3b, ornament = "heart", ornamentColor = 0xffd1ed },
	["plate-royal"] = { fill = 0x60455a, edge = 0xddbe78, radius = 6, outline = 0x291f3b, ornament = "crown", ornamentColor = 0xffe3a0 },
	["plate-sparklebubble"] = { fill = 0xeab3d8, edge = 0xffddf5, radius = 18, ink = 0x48213e, outline = 0xffe9f6,
		art = "sparkles", glow = 0xffd4f1 },
	["plate-enchanted"] = { fill = 0x695342, edge = 0xb69a75, radius = 8, outline = 0x291f3b, ornament = "mushroom", glow = 0xe9cda5 },
	["plate-ribbon"] = { gradient = { 0x72508c, 0x47668d, 0x8a536e }, edge = 0x9e7fb1, radius = 8, outline = 0x291f3b },
	["plate-celestial"] = { gradient = { 0x171d49, 0x3b2d69 }, edge = 0xa397e9, radius = 8, outline = 0x161635, art = "stars",
		glow = 0x5f49af },
	["plate-royalgold"] = { fill = 0x60455a, edge = 0xddbe78, edgeWidth = 1.5, radius = 6, outline = 0x291f3b, ornament = "crown",
		ornamentColor = 0xffe3a0, art = "sweep" },
	["plate-holographic"] = { gradient = { 0xa6b8d6, 0xdab7d5, 0xb5e2d1, 0xbaa5da }, period = 6, edge = 0xe8e0f5, radius = 8,
		ink = 0x342947, outline = 0xf4efff },
	["plate-starglitter"] = { gradient = { 0x714c20, 0x34241a, 0x825626 }, edge = 0xf2d28a, radius = 8, outline = 0x35220b,
		art = "glitter", glow = 0xffdb6d },
} :: {[string]: Plate})

Looks.GLOWS = table.freeze({
	["glow-soft-white"] = 0xeeeaff, ["glow-cyan"] = 0x66ddff, ["glow-pink"] = 0xff99d5, ["glow-green"] = 0x7fe3a1,
	["glow-orange"] = 0xffb26b, ["glow-purple"] = 0xc5a0ff, ["glow-gold"] = 0xe9c46a,
} :: {[string]: number})

function Looks.name(id: string?): Name?
	return if id then Looks.NAMES[id] else nil
end

function Looks.plate(id: string?): Plate?
	return if id then Looks.PLATES[id] else nil
end

function Looks.glow(id: string?): number?
	return if id then Looks.GLOWS[id] else nil
end

-- Whether a name or plate moves (and so redraws as time passes).
function Looks.moving(names: string?, plates: string?): boolean
	local name, plate = Looks.name(names), Looks.plate(plates)
	return (name ~= nil and name.gradient ~= nil) or (plate ~= nil and (plate.period ~= nil or plate.art == "stars"
		or plate.art == "glitter" or plate.art == "sweep"))
end

-- What every player here wears, by account id (client/Multiplayer keeps it
-- from their avatars' identities), for name tags drawn outside the 3D world:
-- the mini-games' own figures (widgets/PlayerTag).
local worn: {[number]: Shop.Look} = {}
-- Told when anyone's look changes; ticked (TICK_RATE a second) while an
-- animated tag is showing and looks may move.
Looks.changed = foundation.ChangeNotifier()
Looks.ticker = foundation.ChangeNotifier()
local clock = 0
local still = false -- the viewer's reduce-motion setting (client/Shop)
local TICK_RATE = 15
local moving = 0 -- animated tags showing
local since = 0

function Looks.of(player: number?): Shop.Look?
	return if player then worn[player] else nil
end

-- [player] wears [look] (nil: nothing from the shop).
function Looks.set(player: number, look: Shop.Look?)
	local before = worn[player]
	if look and Shop.plain(look) then look = nil end
	if before == look or (before and look and before.names == look.names and before.plates == look.plates
		and before.glows == look.glows) then return end
	worn[player] = look
	Looks.changed:notifyListeners()
end

-- Another place: its own players.
function Looks.clear()
	table.clear(worn)
	Looks.changed:notifyListeners()
end

-- An animated tag starts or stops showing.
function Looks.watch(on: boolean)
	moving = math.max(0, moving + (if on then 1 else -1))
end

-- Seconds the looks have been animating (what animated tags are drawn at).
function Looks.time(): number return clock end

function Looks.isStill(): boolean return still end
function Looks.setStill(on: boolean) still = on end

function Looks.tick(dt: number)
	clock += dt
	if moving == 0 or still then return end
	since += dt
	if since >= 1 / TICK_RATE then
		since = 0
		Looks.ticker:notifyListeners()
	end
end

return table.freeze(Looks)
