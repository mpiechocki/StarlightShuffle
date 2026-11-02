--!strict
--@client
-- The lobby's chat, ported from Sky Lounge: the message history, sending,
-- typing indicators, and the labels over avatars (widgets/PlayerLabels),
-- projected each frame: speech bubbles and typing dots over other players'
-- heads (your own speech too), and name tags under them that stay faint until
-- you walk up to them. The avatars, their names and who we are come from
-- client/Multiplayer; where reports go, from the server's CHAT. Other
-- players' messages that the platform keeps can be picked for a menu
-- (Chat.pick, widgets/MessageMenu) that reports them (Chat.report). The
-- chat's ground rules show before a player's first message on a device
-- (Chat.askRules, widgets/ChatRules). Name tags wear their player's name style
-- and nameplate from the shop (their identity's look, widgets/Cosmetics);
-- yours shows too while you wear one, and during a mini-game (`cosmeticOnly`)
-- only those tags show.
local client = require("@moonbase/client")
local preferences = require("@moonbase/preferences")
local engine = require("@moonbase/engine")
local game = require("@moonbase/game")
local Net = require("../shared/Net")
local Controls = require("../gameplay/Controls")
local Multiplayer = require("./Multiplayer")
local Roster = require("./Roster")
local Shop = require("../shared/Shop")
local Looks = require("./Looks")

local BUBBLE_TIME = 6 -- seconds a message stays over its speaker
local COOLDOWN = Net.CHAT_COOLDOWN + 0.3 -- leave the server's limit some network slack
local TYPING_IDLE = 5 -- seconds after the last keystroke that you stop counting as typing
local MARGIN = 140 -- logical pixels; labels hang past their anchor, the layer clips
-- Metres between your avatar and another: their name tag is fully shown
-- within NAME_NEAR and fades down to NAME_FAINT by NAME_FAR, where it stays.
local NAME_NEAR = 0.5
local NAME_FAR = 1.25
local NAME_FAINT = 0.3
-- Seconds per cycle of the typing dots. They step with the game's ticks
-- rather than as a Flutter animation, which would redraw the whole label
-- layer at the display's full rate for as long as anyone types.
local DOTS_PERIOD = 1.1
-- Animated name tags step at this rate (a tick each would redraw them at the game's).
local LOOK_STEPS = 15
-- The faintest a name tag in a shop look gets, however far away.
local LOOK_FAINT = 0.85
-- The chat rules' version a player accepted on this device ("chat.rules" in
-- the experience's preferences): raising it shows the rules again.
local RULES = 1

-- [roles] are the speaker's when they said it (Net.roles), [player] and
-- [avatar] (their thumbnail's media id) whose head to show, and [at] when it
-- came, on this controller's clock. [id] is the platform's, for reports.
export type Line = { key: number, from: number, name: string, text: string, roles: {string},
	player: number, avatar: string?, at: number, id: string? }
-- A name tag hangs below (x, y) and shows its player's `roles`, and whether
-- they are `idle` (always false here: the lobby does not track it); a bubble's tail points down at it. A bubble
-- shows `text` (empty for none) and typing dots while `typing`, `dots` (0..1)
-- through their cycle; `since` is when its text was said (-1 for typing
-- alone), so the newest keeps its place when bubbles crowd.
-- A name tag's `look` is its player's name style and plate (nil: the plain
-- tag), drawn at time `t` (0 for still looks).
export type Label = { key: string, x: number, y: number, text: string, typing: boolean, dots: number, bubble: boolean, opacity: number,
	roles: {string}?, idle: boolean, since: number, look: Shop.Look?, t: number }
type Said = { text: string, at: number }

type Fields = {
	controls: Controls.Controller, multiplayer: Multiplayer.Controller,
	-- The experience whose chat the platform keeps (CHAT), for reports.
	experience: string?,
	time: number, sentAt: number?, serial: number,
	lines: {Line}, said: {[number]: Said},
	-- Other players typing right now; when you last edited a draft, and what
	-- the server was last told about you.
	typing: {[number]: boolean}, editedAt: number?, typingSent: boolean,
	-- The labels shown, and whether the label layer is still popping some in
	-- (it steps them on this clock, so it needs every tick until done).
	labels: {Label}, popping: boolean,
	onLinesChanged: (() -> ())?, onLabelsChanged: (() -> ())?,
	-- The always-shown feed of the latest lines (widgets/ChatFeed), told as the history is.
	onFeedChanged: (() -> ())?,
	-- Set by the chat bar: closes it for typing (its field's focus, and so the
	-- keyboard, and the emoji panel); true when it was open.
	dismissInput: (() -> boolean)?,
	-- Set by the chat bar: how far up from the bottom of the view it reaches,
	-- in logical pixels, with whatever is open above it.
	covered: (() -> number)?,
	-- Another player's message picked for its menu (widgets/MessageMenu), and
	-- who hears when that changes.
	picked: Line?, onPicked: (() -> ())?,
	-- What waits on the chat rules while they show (widgets/ChatRules), and
	-- who hears when they show or go away.
	rulesNext: (() -> ())?, onRules: (() -> ())?,
	-- Only tags with a shop look (during a mini-game); and whether looks stand still (client/Shop's setting).
	cosmeticOnly: boolean, stillLooks: boolean,
	unsubscribe: (() -> ())?,
}
local Chat = {}
Chat.__index = Chat
export type Controller = typeof(setmetatable({} :: Fields, Chat))

function Chat.new(controls: Controls.Controller, multiplayer: Multiplayer.Controller): Controller
	local self = setmetatable({
		controls = controls, multiplayer = multiplayer, experience = nil,
		time = 0, sentAt = nil, serial = 0,
		lines = {}, said = {}, typing = {}, editedAt = nil, typingSent = false, labels = {}, popping = false,
		onLinesChanged = nil, onLabelsChanged = nil, onFeedChanged = nil, dismissInput = nil, covered = nil, picked = nil, onPicked = nil,
		rulesNext = nil, onRules = nil, cosmeticOnly = false, stillLooks = false, unsubscribe = nil,
	} :: Fields, Chat)
	self.unsubscribe = client.onMessage(function(kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown, e: unknown)
		if kind == Net.CHAT then
			self.experience = Net.experience(a)
			return
		elseif kind == Net.TYPING then
			local id = Net.id(a)
			if id and type(b) == "boolean" then self.typing[id] = if b then true else nil end
			return
		elseif kind ~= Net.SAY then
			return
		end
		local from, text = Net.id(a), Net.text(c)
		if not from or type(b) ~= "string" or not text then return end
		self.typing[from] = nil
		self.serial += 1
		-- Who it is, while their avatar is here to say: the line keeps it after they go.
		local speaker = self.multiplayer.avatars[from]
		local player, avatar: string? = 0, nil
		if speaker then
			player = speaker.identity.player
			avatar = speaker.identity.avatar or (if speaker.mine then self.multiplayer.avatar else nil)
		end
		table.insert(self.lines, { key = self.serial, from = from, name = b, text = text, roles = Net.roles(d),
			player = player, avatar = avatar, at = self.time, id = Net.messageId(e) })
		if #self.lines > Net.CHAT_KEEP then table.remove(self.lines, 1) end
		self.said[from] = { text = text, at = self.time }
		if self.onLinesChanged then self.onLinesChanged() end
		if self.onFeedChanged then self.onFeedChanged() end
	end)
	return self
end

function Chat.isMine(self: Controller, from: number): boolean
	local me = self.multiplayer.me
	return me ~= nil and me.id == from
end

-- Sends [raw] unless it is empty or too long, or the previous message was too
-- recent for the server to take another. Returns whether it went out.
function Chat.send(self: Controller, raw: string): boolean
	local text, last = Net.text(raw), self.sentAt
	if not text or (last and self.time - last < COOLDOWN) then return false end
	self.sentAt = self.time
	client.notifyServer(Net.SAY, text)
	-- The message itself ends your typing for everyone.
	self.editedAt, self.typingSent = nil, false
	return true
end

-- The app path that reports [line], or nil when it cannot be: your own lines,
-- a crowd's and any the platform does not keep have no id, and only players
-- with a profile can be reported.
function Chat.reportLink(self: Controller, line: Line): string?
	local id, experience = line.id, self.experience
	if not experience or not id or self:isMine(line.from) or not Roster.linkable({player = line.player, mine = false}) then
		return nil
	end
	return Roster.chatReport(experience, id, line.player, line.name)
end

-- Picks [line] for its menu, the keyboard and emoji panel put away, or puts
-- the menu away (nil). Only messages that can be reported have one: false
-- for any other.
function Chat.pick(self: Controller, line: Line?): boolean
	if line and not self:reportLink(line) then return false end
	if line and self.dismissInput then self.dismissInput() end
	if line ~= self.picked then
		self.picked = line
		if self.onPicked then self.onPicked() end
	end
	return true
end

-- Opens the app's report sheet for [line] over the game, its menu put away;
-- false when it cannot be reported.
function Chat.report(self: Controller, line: Line): boolean
	local link = self:reportLink(line)
	if not link then return false end
	self:pick(nil)
	if self.dismissInput then self.dismissInput() end
	game.openLink(link, false)
	return true
end

-- Whether the player accepted the chat rules on this device.
function Chat.rulesAccepted(_: Controller): boolean
	return preferences.experience:get("chat.rules") == RULES
end

-- Shows the chat rules, [next] to run once they are accepted; nil puts them
-- away unaccepted.
function Chat.askRules(self: Controller, next: (() -> ())?)
	self.rulesNext = next
	if self.onRules then self.onRules() end
end

-- Accepts the chat rules on this device and does what waited on them.
function Chat.acceptRules(self: Controller)
	preferences.experience:set("chat.rules", RULES)
	local next = self.rulesNext
	self:askRules(nil)
	if next then next() end
end

-- The draft changed by the user's hand; a blank one is not typing.
function Chat.typed(self: Controller, draft: string)
	self.editedAt = if string.find(draft, "%S") then self.time else nil
end

-- Point [i] of [projected] (camera:worldToScreenPoints) on a [width] x
-- [height] view, or nil when it is behind the camera or far off screen.
local function screen(projected: {read number}, i: number, width: number, height: number): (number?, number?)
	local x, y = projected[i * 3 - 2], projected[i * 3 - 1]
	if not (projected[i * 3] > 0) then return nil, nil end
	if x < -MARGIN or y < -MARGIN or x > width + MARGIN or y > height + MARGIN then return nil, nil end
	-- Half-pixel steps keep a still avatar's labels from rebuilding.
	return math.round(x * 2) / 2, math.round(y * 2) / 2
end

-- The part of a look a name tag wears (its name style and plate), or nil
-- for a plain tag. Glows are the avatar's own (client/Multiplayer).
local function tagLook(look: Shop.Look?): Shop.Look?
	if not look or (look.names == Shop.DEFAULTS.names and look.plates == Shop.DEFAULTS.plates) then return nil end
	return look
end

-- Label keys by player, made once rather than every frame.
local nameKeys: {[number]: string} = setmetatable({}, {__index = function(keys, id)
	local key = "name:" .. id; keys[id] = key; return key
end}) :: any
local bubbleKeys: {[number]: string} = setmetatable({}, {__index = function(keys, id)
	local key = "bubble:" .. id; keys[id] = key; return key
end}) :: any

local function sameLabels(a: {Label}, b: {Label}): boolean
	if #a ~= #b then return false end
	for i, label in a do
		local other = b[i]
		if label.key ~= other.key or label.x ~= other.x or label.y ~= other.y or label.text ~= other.text
			or label.typing ~= other.typing or label.dots ~= other.dots or label.opacity ~= other.opacity
			or label.roles ~= other.roles or label.idle ~= other.idle or label.look ~= other.look or label.t ~= other.t then return false end
	end
	return true
end

function Chat.update(self: Controller, dt: number)
	self.time += dt
	for id, said in self.said do
		if self.time - said.at > BUBBLE_TIME then self.said[id] = nil end
	end
	local edited = self.editedAt
	local typing = edited ~= nil and self.time - edited < TYPING_IDLE
	if typing ~= self.typingSent then
		self.typingSent = typing
		client.notifyServer(Net.TYPING, typing)
	end
	-- Nothing to project without a mounted label layer.
	local notify = self.onLabelsChanged
	if not notify then return end
	local names: {Label}, bubbles: {Label} = {}, {}
	local scene = self.controls.scene
	local viewport = if scene and scene.isValid then scene.viewport else nil
	local camera = if scene and scene.isValid then scene.activeCamera else nil
	if scene and viewport and camera then
		local mine = self.controls.playerEntity
		local here = if mine and mine.isValid then mine.transform.worldPosition else nil
		-- Every label's anchor first, then one projection for all of them:
		-- a name tag's (with its text and opacity) and a bubble's, in order.
		local points: {vector}, anchors: {{any}} = {}, {}
		local function place(id: number, name: string?, roles: {string}?, entity: engine.Entity?, transform: engine.Transform?,
			look: Shop.Look?, mine: boolean?)
			if not entity or not entity.isValid or not entity.enabled then return end
			local foot = (transform or entity.transform).worldPosition
			if name and here and (look or not self.cosmeticOnly) then
				-- Twentieths keep a slow approach from rebuilding every frame; your own is always clear.
				local nearness = if mine then 1 else math.clamp((NAME_FAR - vector.magnitude(foot - here)) / (NAME_FAR - NAME_NEAR), 0, 1)
				local opacity = math.round((NAME_FAINT + (1 - NAME_FAINT) * nearness) * 20) / 20
				-- A shop look stays nearly whole far off: its plate and colour should read as bought.
				if look then opacity = math.max(opacity, LOOK_FAINT) end
				table.insert(points, foot)
				table.insert(anchors, {id, name, opacity, roles, false, look})
			end
			local said, typing = self.said[id], self.typing[id] == true
			if said or typing then
				-- Over the top of what the outfit draws (its renderer bounds), above where the player stands, so a bag
				-- or a wing out to one side does not pull it off the head.
				local bounds = scene.queries:rendererBounds({ entity = entity, includeDescendants = true, camera = camera })
				local head = if bounds then vector.create(foot.x, bounds.max.y, foot.z)
					else foot + vector.create(0, 1.6, 0)
				table.insert(points, head)
				table.insert(anchors, {id, false, said, typing})
			end
		end
		-- Your own speech shows over you; your name only while you wear a shop look.
		local multiplayer = self.multiplayer
		local me = multiplayer.me
		local ownLook: Shop.Look? = nil
		for id, avatar in multiplayer.avatars do
			-- A name settles in once its avatar has landed.
			local name = if avatar.arriving then nil else avatar.identity.name
			local look = tagLook(avatar.identity.look)
			if not avatar.mine then place(id, name, nil, avatar.parts.entity, avatar.controller.transform, look)
			elseif me and me.id == id and not avatar.arriving then ownLook = look end
		end
		if me then
			local own = multiplayer.avatars[me.id]
			place(me.id, if ownLook and own then own.identity.name else nil, nil, mine, nil, ownLook, true)
		end
		if #points > 0 then
			local projected = camera:worldToScreenPoints({ points = points, viewport = viewport })
			local width, height = viewport.width, viewport.height
			for i, anchor in anchors do
				local x, y = screen(projected, i, width, height)
				if not x or not y then continue end
				local id = anchor[1]
				if anchor[2] then
					local look: Shop.Look? = anchor[6]
					local moving = look ~= nil and not self.stillLooks and Looks.moving(look.names, look.plates)
					table.insert(names, { key = nameKeys[id], x = x, y = y + 3, text = anchor[2], typing = false, dots = 0, bubble = false,
						opacity = anchor[3], roles = anchor[4], idle = anchor[5], since = 0, look = look,
						t = if moving then math.floor(self.time * LOOK_STEPS) / LOOK_STEPS else 0 })
				else
					local said, typed = anchor[3], anchor[4]
					table.insert(bubbles, { key = bubbleKeys[id], x = x, y = y, text = if said then said.text else "",
						typing = typed, dots = if typed then self.time % DOTS_PERIOD / DOTS_PERIOD else 0, bubble = true, opacity = 1,
						roles = nil, idle = false, since = if said then said.at else -1, look = nil, t = 0 })
				end
			end
		end
	end
	-- Bubbles draw over every name tag.
	table.move(bubbles, 1, #bubbles, #names + 1, names)
	if sameLabels(names, self.labels) and not self.popping then return end
	self.labels = names
	notify()
end

-- A player's avatar left our view: so do their bubble and typing dots.
function Chat.left(self: Controller, id: number)
	self.typing[id], self.said[id] = nil, nil
end

-- The chat is put away (a cycle's break is over): bubbles and typing dots go,
-- and if we were typing, we stop; the history stays for the next break.
function Chat.quiet(self: Controller)
	table.clear(self.said); table.clear(self.typing)
	self.editedAt = nil
	if self.typingSent then
		self.typingSent = false
		client.notifyServer(Net.TYPING, false)
	end
	self:pick(nil)
	self.rulesNext = nil
end

-- Another server instance has its own chat and typists (or none, in a
-- cycle): it starts empty.
function Chat.reset(self: Controller)
	self.experience, self.editedAt = nil, nil
	table.clear(self.lines); table.clear(self.said); table.clear(self.typing)
	self.typingSent = false
	self:pick(nil)
	if self.onLinesChanged then self.onLinesChanged() end
	if self.onFeedChanged then self.onFeedChanged() end
end

function Chat.dispose(self: Controller)
	if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
	self.onLinesChanged, self.onLabelsChanged, self.dismissInput, self.covered = nil, nil, nil, nil
	self.onFeedChanged = nil
	self.picked, self.onPicked = nil, nil
	table.clear(self.lines); table.clear(self.said); table.clear(self.typing); table.clear(self.labels)
end

return Chat
