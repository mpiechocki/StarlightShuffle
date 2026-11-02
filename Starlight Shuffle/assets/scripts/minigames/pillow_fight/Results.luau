--!strict
--@client
-- Pillow Fight's results in the shared results card: your room first (its
-- one winner large, with the reward, then every place in your room), a short
-- note of anyone who left during the fight, and below, only when there were
-- other rooms, "Winners from other rooms": one winner per room. The cycle
-- moves on by itself.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local ui = require("@dart/ui")
local Rules = require("./Rules")
local Model = require("./Model")
local Art = require("./Art")
local Pieces = require("./Pieces")
local GameUi = require("../../widgets/GameUi")

local C = Rules.CONFIG
local style = GameUi.style

local function color(v: number): ui.Color return ui.Color({value = v}) end

type Model = Model.Model

local function nameOf(model: Model, id: number): string
	local pt = model.participants[id]
	return if pt then pt.name else "Player"
end

-- A small four-point sparkle over the winner.
local sparkle: ui.Path? = nil
local function paintSparkle(canvas: ui.Canvas, size: ui.Size)
	local path = sparkle
	if not path then
		path = ui.Path({})
		path:moveTo(0, -1); path:quadraticBezierTo(0.12, -0.12, 1, 0); path:quadraticBezierTo(0.12, 0.12, 0, 1)
		path:quadraticBezierTo(-0.12, 0.12, -1, 0); path:quadraticBezierTo(-0.12, -0.12, 0, -1); path:close()
		sparkle = path
	end
	canvas:save()
	canvas:translate(size.width / 2, size.height / 2)
	canvas:scale(size.height / 2, size.height / 2)
	canvas:drawPath(path :: ui.Path, Art.paint(0xffdc91))
	canvas:restore()
end

local function reward(pt: Rules.Participant?): string
	if pt and pt.bot then return "Bot winner · no Starlights" end
	return "+" .. C.WINNER_STARLIGHTS .. " Starlights"
end

local function standing(model: Model, placement: Rules.Placement): w.Widget
	local mine = placement.participant == model.me
	return GameUi.row(w.Row({children = {
		GameUi.medal(placement.place),
		w.SizedBox({width = 10}),
		Pieces.head(model.participants[placement.participant], 34),
		w.SizedBox({width = 10}),
		w.Expanded({child = w.Text.rich({maxLines = 1, overflow = w.TextOverflow.ellipsis, textSpan = p.TextSpan({children = {
			p.TextSpan({text = nameOf(model, placement.participant), style = style(15, GameUi.TEXT, ui.FontWeight.w800)}),
			p.TextSpan({text = if mine then "  you" else "", style = style(11, GameUi.MUTED, ui.FontWeight.w700)}),
		}})})}),
		w.Text({data = placement.score .. (if placement.score == 1 then " pt" else " pts"), style = style(14, GameUi.SOFT, ui.FontWeight.w800)}),
	}}), mine, "place" .. placement.place)
end

local Results = {}

-- The card is rebuilt only when the results or the seconds shown change.
local built: { results: {Rules.RoomResult}, seconds: number, widget: w.Widget }? = nil

function Results.view(model: Model): w.Widget?
	local results = model.results
	local round = model.round()
	if not results or not round or round.phase ~= "results" then return nil end
	local seconds = math.max(0, math.ceil(model.nextIn()))
	if built and built.results == results and built.seconds == seconds then return built.widget end
	local ours = results[1]
	if not ours then return nil end
	local children: {w.Widget} = {}
	local watching = model.me == nil
	if ours.status == "completed" and ours.winner then
		local winner = model.participants[ours.winner]
		table.insert(children, w.Text({data = if watching then "Room " .. ours.room .. " winner" else "Your room winner",
			textAlign = ui.TextAlign.center, style = style(24, GameUi.TEXT, ui.FontWeight.w700, -0.4, true)}))
		table.insert(children, w.SizedBox({height = 8}))
		table.insert(children, w.Center({child = w.SizedBox({width = 22, height = 22, child = Pieces.paint(paintSparkle)})}))
		table.insert(children, w.Center({child = Pieces.body(winner, 80, 128)}))
		table.insert(children, w.SizedBox({height = 6}))
		table.insert(children, w.Text({data = nameOf(model, ours.winner), textAlign = ui.TextAlign.center, maxLines = 2,
			overflow = w.TextOverflow.ellipsis, style = style(18, color(0xfffff0dd), ui.FontWeight.w800)}))
		table.insert(children, w.SizedBox({height = 3}))
		table.insert(children, w.Text({data = reward(winner), textAlign = ui.TextAlign.center, style = style(12, color(0xffffe4ab), ui.FontWeight.w800)}))
		if ours.tieBreak and ours.tieBreak ~= "score" then
			table.insert(children, w.Text({data = "Won on tie-break", textAlign = ui.TextAlign.center, style = style(11, GameUi.MUTED, ui.FontWeight.w700)}))
		end
		table.insert(children, w.SizedBox({height = 14}))
	else
		table.insert(children, w.Text({data = "This fight ended early.", textAlign = ui.TextAlign.center,
			style = style(24, GameUi.TEXT, ui.FontWeight.w700, -0.4, true)}))
		table.insert(children, w.SizedBox({height = 6}))
		table.insert(children, w.Text({data = "No winner and no Starlights this time.", textAlign = ui.TextAlign.center,
			style = style(13, GameUi.SOFT)}))
		table.insert(children, w.SizedBox({height = 14}))
	end
	for _, placement in ours.placements do table.insert(children, standing(model, placement)) end
	if #ours.forfeits > 0 then
		local names: {string} = {}
		for _, id in ours.forfeits do table.insert(names, nameOf(model, id)) end
		table.insert(children, w.Text({data = "Left during the fight (a bot took their seat): " .. table.concat(names, ", "),
			style = style(11, GameUi.MUTED, ui.FontWeight.w700)}))
	end
	local others: {w.Widget} = {}
	for i = 2, #results do
		local room = results[i]
		if room.status == "completed" and room.winner then
			local winner = model.participants[room.winner]
			table.insert(others, w.Container({key = w.ValueKey({value = "room" .. room.room}),
				padding = p.EdgeInsets.symmetric({vertical = 7}),
				decoration = p.BoxDecoration({border = p.Border({top = p.BorderSide({color = color(0x26ffffff), width = 1})})}),
				child = w.Row({children = {
					w.SizedBox({width = 56, child = w.Text({data = "Room " .. room.room, style = style(11, GameUi.MUTED, ui.FontWeight.w800)})}),
					Pieces.head(winner, 28),
					w.SizedBox({width = 9}),
					w.Expanded({child = w.Text({data = nameOf(model, room.winner), maxLines = 1, overflow = w.TextOverflow.ellipsis,
						style = style(13, GameUi.TEXT, ui.FontWeight.w700)})}),
					w.Text({data = if winner and winner.bot then "bot" else "+" .. C.WINNER_STARLIGHTS,
						style = style(12, color(0xffffe3ab), ui.FontWeight.w800)}),
				}})}))
		end
	end
	if #others > 0 then
		table.insert(children, w.SizedBox({height = 14}))
		table.insert(children, w.Text({data = "Winners from other rooms", style = style(16, GameUi.SOFT, ui.FontWeight.w700, -0.2, true)}))
		table.insert(children, w.SizedBox({height = 6}))
		for _, row in others do table.insert(children, row) end
	end
	table.insert(children, w.SizedBox({height = 10}))
	table.insert(children, w.Text({data = "Next mini-game in " .. seconds .. "s", textAlign = ui.TextAlign.center,
		style = style(12, GameUi.MUTED, ui.FontWeight.w700)}))
	local widget = GameUi.wrap(children)
	built = { results = results, seconds = seconds, widget = widget }
	return widget
end

return table.freeze(Results)
