--!strict
--@client
-- A card that explains something once: a title, an optional line under it,
-- rows of an icon, a short title and a line or two under
-- it, and one button. The chat rules (widgets/ChatRules) show one.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local mdi = require("@icons/mdi")
local Style = require("./ChatStyle")

local InfoCard = {}

-- The line under the title and under each row's title; rich text such as a
-- price builds on it.
InfoCard.DETAIL = p.TextStyle({fontSize = 13, color = Style.HINT, height = 1.35})

-- A row title's line height: its mark is centred on the first line.
local LINE = 20
local TITLE = p.TextStyle({fontSize = 14, color = Style.WHITE, fontWeight = ui.FontWeight.w700, height = LINE / 14})

export type Row = {
	-- InfoCard.icon.
	mark: w.Widget,
	title: string,
	detail: w.Widget,
}
export type Props = {
	title: string, intro: string?, rows: {Row},
	accept: string, key: string, onAccept: () -> (),
}

function InfoCard.icon(icon: mdi.IconRef): w.Widget
	return w.Icon({icon = icon, size = 18, color = Style.ACCENT})
end

-- Plain text under a row's title, wrapping onto as many lines as it needs.
function InfoCard.detail(text: string): w.Widget
	return w.Text({data = text, style = InfoCard.DETAIL})
end

local function row(entry: Row): w.Widget
	return w.Row({crossAxisAlignment = w.CrossAxisAlignment.start, children = {
		w.SizedBox({width = 22, height = LINE, child = w.Center({child = entry.mark})}),
		w.SizedBox({width = 10}),
		w.Expanded({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, children = {
			w.Text({data = entry.title, style = TITLE}),
			w.SizedBox({height = 2}),
			entry.detail,
		}})}),
	}})
end

function InfoCard.card(props: Props): w.Widget
	local children: {w.Widget} = {
		w.Text({data = props.title, style = Style.style(18, Style.WHITE, ui.FontWeight.w700)}),
	}
	if props.intro then
		table.insert(children, w.SizedBox({height = 6}))
		table.insert(children, w.Text({data = props.intro, style = InfoCard.DETAIL}))
	end
	for i, entry in props.rows do
		table.insert(children, w.SizedBox({height = if i == 1 then 20 else 16}))
		table.insert(children, row(entry))
	end
	table.insert(children, w.SizedBox({height = 24}))
	table.insert(children, Style.button({label = props.accept, kind = "filled", height = 46, key = props.key, onTap = props.onAccept}))
	return w.ConstrainedBox({constraints = r.BoxConstraints({maxWidth = 360}),
		child = w.Container({padding = p.EdgeInsets.fromLTRB(24, 24, 24, 20), decoration = p.BoxDecoration({color = Style.SURFACE,
			borderRadius = p.BorderRadius.circular(24), border = p.Border.all({color = Style.LINE})}),
			child = w.Column({mainAxisSize = w.MainAxisSize.min, crossAxisAlignment = w.CrossAxisAlignment.stretch,
				children = children})})})
end

return table.freeze(InfoCard)
