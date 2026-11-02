--!strict
--@client
-- What Pillow Fight's screens read: the round as this client knows it (kept
-- by Client from the server's messages) and the player's actions.
local foundation = require("@flutter/foundation")
local Rules = require("./Rules")

export type Effect = { participant: number, at: number } -- game.clock() it happened
export type Model = {
	frame: foundation.ChangeNotifier, -- every frame
	changed: foundation.ChangeNotifier, -- roster, room or results changes
	ready: boolean,
	schedule: Rules.Schedule,
	participants: {[number]: Rules.Participant}, -- by participant id
	roster: {Rules.Participant}, -- everyone, rooms then seats
	me: number?, -- our participant id when we fight
	room: number, -- the room shown (ours, or room 1 when watching)
	actors: {[number]: Rules.Actor}, -- the shown room's seats, by seat
	projectiles: {Rules.Projectile},
	target: number?, -- the rival we aim at (participant id)
	charging: boolean, chargeStartedAt: number, -- game.clock()
	dodgeUntil: number, -- game.clock() a dodge we sent shows until (before the server's word)
	hits: {Effect}, throws: {Effect}, hurtAt: number,
	results: {Rules.RoomResult}?,
	lesson: number?, -- an example picked with the dots
	reduced: boolean,
	round: () -> any,
	nextIn: () -> number,
	now: (Model) -> number, -- the server's clock
	-- Our seat's live state, when we fight.
	mine: (Model) -> Rules.Actor?,
	choose: (Model, participant: number) -> (),
	-- A finger (or Space/Enter, pointer -1) goes down on Throw, or lifts.
	press: (Model, pointer: number) -> (),
	release: (Model, pointer: number, cancelled: boolean) -> (),
	dodge: (Model) -> (),
}

return {}
