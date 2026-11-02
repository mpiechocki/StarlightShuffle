--!strict
--@client
-- The lobby shop (client/Shop), after the shop preview's mobile layout at
-- every screen size: a portrait panel at most 447 wide, centred over the
-- dimmed lobby. Its header (title, both balances, the four tabs) and footer
-- (the selection and its action) stay put while the middle scrolls: your
-- look (name and plate over your avatar with its glow, the three slots, and
-- whether it is the saved look or a preview), then the tab's items two to a
-- row, cheapest first. The boosters tab hides your look and shows your
-- earnings, running booster and unused tokens instead. Purchases, booster
-- activations and settings open dialogs over the panel, which keep the
-- keyboard's focus until they close. Admins also get "Test tools" (the flask
-- in the header): Starlight and test-Star grants, simulated rewards, faults
-- for the next Stars purchase, booster expiry and an account reset.
local w = require("@flutter/widgets")
local p = require("@flutter/painting")
local r = require("@flutter/rendering")
local ui = require("@dart/ui")
local m = require("@flutter/material")
local fonts = require("@fonts/app")
local material = require("@icons/material")
local Shop = require("../shared/Shop")
local Controller = require("../client/Shop")
local Cosmetics = require("./Cosmetics")
local Pressable = require("./Pressable")
local Style = require("./Style")

local function color(argb: number): ui.Color return ui.Color({value = argb}) end
local PANEL = color(0xff19152f)
local PANEL_EDGE = color(0xff514466)
local CARD = color(0xff282243)
local CARD_EDGE = color(0xff3c3157)
local CARD_PICKED = color(0xff302546)
local PICKED_EDGE = color(0xffb7a1f5)
local LINE = color(0xff40365f)
local DIVIDER = color(0xff332b4e)
local MUTED = color(0xffb8b0ce)
local ACCENT = color(0xffb6a0f5)
local INK = color(0xfff8f5ff)
local ON_ACCENT = color(0xff211733)
local GOLD = color(0xffffe08c)
local NOTICE = color(0xffe9c89b)
local OWNED = color(0xffc9baff)
local BALANCE = color(0xff211a37)
local TAB_ON = color(0xff393052)
local TAB_EDGE = color(0xff705b9b)
local SLOT = color(0xff25203c)
local FOOTER = color(0xff1c1732)
local DIALOG = color(0xff201a36)
local DIALOG_EDGE = color(0xff63507c)
local SCRIM = color(0xb80e0a21)
local DIM = color(0x8c120c26)
local TOAST = color(0xffe4d9ff)
local TOAST_INK = color(0xff241936)
local SUMMARY = color(0xff2b2345)
local SUMMARY_EDGE = color(0xff655180)
local STAGE = color(0x4a4d3462)

local MAX_WIDTH = 447

local function style(size: number, colour: ui.Color, weight: ui.FontWeight?): p.TextStyle
	return p.TextStyle({fontFamily = fonts.lato, fontSize = size, color = colour, fontWeight = weight, height = 1.35})
end

local function txt(data: string, size: number, colour: ui.Color, weight: ui.FontWeight?, lines: number?, align: ui.TextAlign?): w.Widget
	return w.Text({data = data, style = style(size, colour, weight), maxLines = lines or 1, overflow = w.TextOverflow.ellipsis,
		textAlign = align})
end

local function gap(size: number): w.Widget return w.SizedBox({width = size, height = size}) end

-- An amount with its currency's icon and name.
local function money(amount: number, currency: Shop.Currency, size: number, colour: ui.Color?, named: boolean?): w.Widget
	return w.Row({mainAxisSize = w.MainAxisSize.min, children = {
		Cosmetics.icon(currency, size + 5),
		gap(5),
		w.Flexible({child = txt(Style.count(amount) .. (if named == false then "" else " " .. Shop.currencyName(currency)), size,
			colour or INK, ui.FontWeight.w700)}),
	}})
end

-- A button: [primary] filled lavender, else outlined; disabled without onTap.
local function button(label: w.Widget | string, onTap: (() -> ())?, primary: boolean, key: string, autofocus: boolean?): w.Widget
	local content: w.Widget = if type(label) == "string"
		then txt(label, 13, if primary then ON_ACCENT else INK, ui.FontWeight.w800, 1, ui.TextAlign.center) else label
	return Pressable({key = w.ValueKey({value = key}), onTap = onTap, focusable = true, radius = 10, autofocus = autofocus,
		label = if type(label) == "string" then label else nil,
		child = w.Opacity({opacity = if onTap then 1 else 0.5, child = w.Container({
			constraints = r.BoxConstraints({minHeight = 42}),
			padding = p.EdgeInsets.symmetric({horizontal = 14, vertical = 10}), alignment = p.Alignment.center,
			decoration = p.BoxDecoration({color = if primary then ACCENT else CARD, borderRadius = p.BorderRadius.circular(10),
				border = p.Border.all({color = if primary then ACCENT else LINE})}),
			child = content})})})
end

local function iconButton(icon: material.IconRef, label: string, onTap: () -> (), key: string): w.Widget
	return Pressable({key = w.ValueKey({value = key}), onTap = onTap, focusable = true, radius = 18, label = label,
		child = w.SizedBox({width = 36, height = 36, child = w.Center({child = w.Icon({icon = icon, size = 24, color = MUTED})})})})
end

type Props = { read shop: Controller.Controller, read clock: () -> number }
type Fields = { unlisten: (() -> ())?, scroll: w.ScrollController? }
type State = w.State<Props, Fields>
local define = w.StatefulWidget.define :: w.StatefulWidgetFactory<Props, Fields>

-- Whether looks stand still: the player's setting or the device's.
local function still(shop: Controller.Controller, context: w.BuildContext): boolean
	return shop:prefs().motion or w.MediaQuery.disableAnimationsOf(context)
end

local function animated(shop: Controller.Controller, clock: () -> number, frozen: boolean, build: (t: number) -> w.Widget): w.Widget
	return Cosmetics.Animated({frame = shop.frame, clock = clock, still = frozen, build = build})
end

local function kindOf(item: Shop.Item): string
	if item.category == "boosters" then return if item.permanent then "Permanent earning boost" else "7-day earning boost" end
	return (if item.animated then "Animated" else "Static") .. " · permanent"
end

local function remaining(ms: number): string
	local minutes = math.max(0, math.ceil(ms / 60000))
	return string.format("%dd %dh %dm", minutes // 1440, (minutes % 1440) // 60, minutes % 60)
end

local function expiry(ms: number): string
	return os.date("%b %d, %Y · %H:%M", math.floor(ms / 1000)) :: string
end

-- Header ---------------------------------------------------------------

local function balances(shop: Controller.Controller): w.Widget
	local function box(currency: Shop.Currency): w.Widget
		local amount = shop:balance(currency)
		return w.Expanded({child = w.Container({
			padding = p.EdgeInsets.symmetric({horizontal = 9, vertical = 8}),
			decoration = p.BoxDecoration({color = BALANCE, borderRadius = p.BorderRadius.circular(11), border = p.Border.all({color = LINE})}),
			child = w.Row({children = {
				Cosmetics.icon(currency, 23),
				gap(7),
				w.Expanded({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = {
					txt(if amount then Style.count(amount) else "—", 15, INK, ui.FontWeight.w800),
					txt(Shop.currencyName(currency), 10, MUTED),
				}})}),
			}}),
		})})
	end
	return w.Row({children = { box("starlight"), gap(7), box("stars") }})
end

local function tabs(shop: Controller.Controller): w.Widget
	local row: {w.Widget} = {}
	for i, category in Shop.CATEGORIES do
		if i > 1 then table.insert(row, gap(2)) end
		local on = shop.category == category
		table.insert(row, w.Expanded({child = Pressable({key = w.ValueKey({value = "shop-tab-" .. category}), focusable = true,
			label = Shop.TITLES[category], selected = on, radius = 10, depth = 0.03,
			onTap = function() shop:setCategory(category) end,
			child = w.Container({padding = p.EdgeInsets.symmetric({horizontal = 2, vertical = 9}), alignment = p.Alignment.center,
				decoration = p.BoxDecoration({color = if on then TAB_ON else color(0), borderRadius = p.BorderRadius.circular(10),
					border = p.Border.all({color = if on then TAB_EDGE else color(0)})}),
				child = txt(Shop.TITLES[category], 11, if on then INK else MUTED, if on then ui.FontWeight.w800 else ui.FontWeight.w600, 1, ui.TextAlign.center)})})}))
	end
	return w.Row({children = row})
end

local function header(shop: Controller.Controller): w.Widget
	return w.Container({
		padding = p.EdgeInsets.fromLTRB(15, 15, 10, 10),
		decoration = p.BoxDecoration({border = p.Border({bottom = p.BorderSide({color = DIVIDER})})}),
		child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = {
			w.Row({children = {
				w.Expanded({child = txt("Shop", 22, INK, ui.FontWeight.w900)}),
				if shop.tester then iconButton(material.science_rounded, "Admin test tools", function() shop:showDialog({ kind = "tests" }) end,
					"shop-tests") else w.SizedBox.shrink({}),
				iconButton(material.tune_rounded, "Settings and history", function() shop:showDialog({ kind = "settings" }) end, "shop-settings"),
				iconButton(material.close_rounded, "Close shop", function() shop:close() end, "shop-close"),
			}}),
			gap(8),
			w.Padding({padding = p.EdgeInsets.only({right = 5}), child = balances(shop)}),
			gap(10),
			w.Padding({padding = p.EdgeInsets.only({right = 5}), child = tabs(shop)}),
		}}),
	})
end

-- Your look ------------------------------------------------------------

local function preview(shop: Controller.Controller, clock: () -> number, frozen: boolean, name: string): w.Widget
	local look = shop.preview
	local account = shop.account
	local prefs = shop:prefs()
	local slots: {w.Widget} = {}
	for i, slot in Shop.SLOTS do
		if i > 1 then table.insert(slots, gap(5)) end
		local id = Shop.slot(look, slot)
		local item = Shop.get(id)
		local worn = if account then Shop.slot(account.equipped, slot) else id
		local clearable = worn ~= Shop.slot(Shop.defaultLook(), slot)
		local label = if slot == "names" then "Name" elseif slot == "plates" then "Nameplate" else "Glow"
		table.insert(slots, w.Expanded({child = w.Container({
			padding = p.EdgeInsets.fromLTRB(4, 6, if clearable then 2 else 4, 6),
			decoration = p.BoxDecoration({color = SLOT, borderRadius = p.BorderRadius.circular(8)}),
			child = w.Row({children = {
				w.Expanded({child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
					txt(label, 9, MUTED, nil, 1, ui.TextAlign.center),
					txt(if item then item.name else "—", 10, INK, ui.FontWeight.w700, 1, ui.TextAlign.center),
				}})}),
				if clearable then Pressable({key = w.ValueKey({value = "shop-unequip-" .. slot}), focusable = true, radius = 6,
					label = "Unequip " .. string.lower(label), onTap = if shop:ready() then function() shop:unequip(slot) end else nil,
					child = w.Padding({padding = p.EdgeInsets.all(2), child = w.Icon({icon = material.close_rounded, size = 13, color = MUTED})})})
					else w.SizedBox.shrink({}),
			}}),
		})}))
	end
	local saved = shop:saved()
	return w.Container({
		padding = p.EdgeInsets.fromLTRB(15, 12, 15, 10),
		decoration = p.BoxDecoration({border = p.Border({bottom = p.BorderSide({color = DIVIDER})}),
			gradient = p.LinearGradient({colors = { color(0xff231d3d), PANEL }, begin = p.Alignment.topLeft, ["end"] = p.Alignment.bottomRight})}),
		child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = {
			w.SizedBox({height = 188, child = w.Stack({children = {
				w.Positioned.fill({child = w.Container({decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(12),
					gradient = p.RadialGradient({colors = { STAGE, color(0) }, center = p.Alignment({x = 0, y = 0.76}), radius = 0.8})})})}),
				w.Positioned.fill({child = w.Column({mainAxisAlignment = w.MainAxisAlignment["end"], children = {
					w.Padding({padding = p.EdgeInsets.symmetric({horizontal = 8}), child = animated(shop, clock, frozen, function(t: number): w.Widget
						return Cosmetics.label(name, look.names, look.plates, t, 14, nil, 260)
					end)}),
					gap(4),
					Cosmetics.avatar(shop.outfit, 110, 143, look.glows, prefs.effects),
				}})}),
				w.Positioned({left = 0, right = 0, top = 0, child = w.Row({children = {
					w.Expanded({child = txt("YOUR LOOK", 10, MUTED, ui.FontWeight.w700)}),
					Pressable({key = w.ValueKey({value = "shop-reset"}), focusable = true, radius = 8, label = "Reset preview",
						onTap = if saved then nil else function() shop:resetPreview() end,
						child = w.Opacity({opacity = if saved then 0.45 else 1, child = w.Container({
							padding = p.EdgeInsets.symmetric({horizontal = 7, vertical = 4}),
							decoration = p.BoxDecoration({borderRadius = p.BorderRadius.circular(8), border = p.Border.all({color = LINE})}),
							child = txt("Reset preview", 10, INK, ui.FontWeight.w600)})})}),
				}})}),
			}})}),
			gap(7),
			w.Row({children = slots}),
			gap(6),
			txt(if saved then "Equipped look · saved" else "Preview only · your saved look has not changed", 10,
				if saved then MUTED else NOTICE, ui.FontWeight.w600, 1, ui.TextAlign.center),
		}}),
	})
end

-- The catalogue --------------------------------------------------------

local function sample(shop: Controller.Controller, clock: () -> number, frozen: boolean, item: Shop.Item): w.Widget
	if item.category == "names" then
		return animated(shop, clock, frozen or not item.animated, function(t: number): w.Widget
			return Cosmetics.name("Name", item.id, t, { size = 14, soft = true })
		end)
	elseif item.category == "plates" then
		return animated(shop, clock, frozen or not item.animated, function(t: number): w.Widget
			return Cosmetics.label("Name", nil, item.id, t, 12, nil, 150)
		end)
	elseif item.category == "glows" then
		return Cosmetics.avatar(shop.outfit, 42, 45, item.id, shop:prefs().effects)
	end
	return w.Column({mainAxisSize = w.MainAxisSize.min, children = {
		txt(string.format("%g×", item.multiplier or 1), 24, color(0xffd5c2ff), ui.FontWeight.w900),
		txt(if item.permanent then "Permanent" else "7 days · activate later", 9, GOLD, ui.FontWeight.w600),
	}})
end

local function card(shop: Controller.Controller, clock: () -> number, frozen: boolean, item: Shop.Item): w.Widget
	local account = shop.account :: Shop.Account
	local owned = Shop.owned(account, item)
	local equipped = shop:isEquipped(item)
	local picked = shop.selected == item.id
	local cost = Shop.cost(account, item)
	local price: w.Widget = if owned
		then txt(if item.category == "boosters" then "Active permanently" elseif equipped then "Currently equipped" else "Ready to equip", 10, OWNED, ui.FontWeight.w700)
		else money(cost, item.currency, 10)
	local children: {w.Widget} = {
		w.SizedBox({height = 45, child = w.Center({child = sample(shop, clock, frozen, item)})}),
		gap(3),
		txt(item.name, 11, INK, ui.FontWeight.w800, 2),
		txt(kindOf(item), 10, MUTED),
	}
	if item.category == "boosters" then
		table.insert(children, gap(4))
		table.insert(children, w.Text.rich({textSpan = p.TextSpan({style = style(10, color(0xffdcd0f5)), children = {
			p.TextSpan({text = "100 Starlight → "}),
			p.TextSpan({text = tostring(math.floor(100 * (item.multiplier or 1))), style = style(12, color(0xfff8edff), ui.FontWeight.w900)}),
		}})}))
	end
	table.insert(children, gap(8))
	table.insert(children, price)
	local label = item.name .. ", " .. kindOf(item) .. ", " .. (if owned then (if equipped then "equipped" else "owned")
		else Style.count(cost) .. " " .. Shop.currencyName(item.currency))
	return Pressable({key = w.ValueKey({value = "shop-item-" .. item.id}), focusable = true, radius = 11, depth = 0.03,
		label = label, selected = picked, onTap = function() shop:select(item.id) end,
		child = w.Container({
			padding = if picked then p.EdgeInsets.fromLTRB(9, 10, 9, 10) else p.EdgeInsets.fromLTRB(10, 11, 10, 11),
			decoration = p.BoxDecoration({color = if picked then CARD_PICKED else CARD, borderRadius = p.BorderRadius.circular(11),
				border = p.Border.all({color = if picked then PICKED_EDGE else CARD_EDGE, width = if picked then 2 else 1})}),
			child = w.Stack({children = {
				w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = children}),
				if owned and item.category ~= "boosters" or (owned and item.permanent) then w.Positioned({right = 0, top = 0,
					child = txt(if equipped then "Equipped" else "Owned", 10, OWNED, ui.FontWeight.w700)}) else w.SizedBox.shrink({}),
			}}),
		})})
end

local function grid(shop: Controller.Controller, clock: () -> number, frozen: boolean, items: {Shop.Item}): w.Widget
	if #items == 0 then
		return w.Padding({padding = p.EdgeInsets.all(30), child = txt("No items here yet. Explore the shop to find your favourites.", 12, MUTED, nil, 3, ui.TextAlign.center)})
	end
	local rows: {w.Widget} = {}
	for i = 1, #items, 2 do
		local left, right = items[i], items[i + 1]
		if i > 1 then table.insert(rows, gap(8)) end
		table.insert(rows, w.IntrinsicHeight({child = w.Row({crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
			w.Expanded({child = card(shop, clock, frozen, left)}),
			gap(8),
			w.Expanded({child = if right then card(shop, clock, frozen, right) else w.SizedBox.shrink({})}),
		}})}))
	end
	return w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = rows})
end

local function filters(shop: Controller.Controller): w.Widget
	local row: {w.Widget} = {}
	for i, entry in { {"all", "All"}, {"starlight", "Starlight"}, {"stars", "Stars"}, {"owned", "Owned"} } do
		local key, label = entry[1] :: Shop.Filter, entry[2]
		local on = shop.filter == key
		if i > 1 then table.insert(row, gap(4)) end
		table.insert(row, Pressable({key = w.ValueKey({value = "shop-filter-" .. key}), focusable = true, radius = 8, depth = 0.04,
			label = label, selected = on, onTap = function() shop:setFilter(key) end,
			child = w.Container({padding = p.EdgeInsets.symmetric({horizontal = 9, vertical = 6}),
				decoration = p.BoxDecoration({color = if on then color(0xff3b3058) else color(0), borderRadius = p.BorderRadius.circular(8),
					border = p.Border.all({color = if on then color(0xff7b629e) else LINE})}),
				child = txt(label, 10, if on then INK else MUTED, ui.FontWeight.w700)})}))
	end
	return w.Wrap({spacing = 0, runSpacing = 4, children = row})
end

local function boostSummary(shop: Controller.Controller): w.Widget
	local account = shop.account :: Shop.Account
	local now = shop:now()
	local multiplier = Shop.multiplier(account, now)
	local active = Shop.active(account, now)
	local activeItem = if active then Shop.get(active.item) else nil
	return w.Container({
		margin = p.EdgeInsets.only({bottom = 14}),
		padding = p.EdgeInsets.all(12),
		decoration = p.BoxDecoration({color = SUMMARY, borderRadius = p.BorderRadius.circular(10), border = p.Border.all({color = SUMMARY_EDGE})}),
		child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = {
			txt(string.format("Your earnings · %g× total", multiplier), 12, color(0xffdecfff), ui.FontWeight.w800),
			gap(4),
			txt("100 base Starlight → " .. math.floor(100 * multiplier) .. " Starlight", 11, INK),
			gap(2),
			txt(if active and activeItem then activeItem.name .. " · " .. remaining(active.expires - now) .. " left"
				elseif account.permanent > 1 then "Permanent booster active" else "No active booster", 11, MUTED),
		}}),
	})
end

local function inventory(shop: Controller.Controller): w.Widget
	local account = shop.account :: Shop.Account
	local now = shop:now()
	local active = Shop.active(account, now)
	local children: {w.Widget} = { txt("Your boosters", 13, INK, ui.FontWeight.w800), gap(6) }
	if account.permanent > 1 then
		table.insert(children, txt(string.format("Permanent multiplier: %g×", account.permanent), 11, MUTED))
		table.insert(children, gap(4))
	end
	if active then
		local item = Shop.get(active.item)
		table.insert(children, txt((if item then item.name else "Weekly booster") .. " active until " .. expiry(active.expires)
			.. " (" .. remaining(active.expires - now) .. " left).", 11, MUTED, nil, 3))
		table.insert(children, gap(6))
	end
	if #account.tokens == 0 then
		table.insert(children, txt("No unused tokens. Weekly purchases start only when you activate them.", 11, MUTED, nil, 3))
	end
	for _, token in account.tokens do
		local item = Shop.get(token.item)
		local why = Shop.activation(account, token, now)
		table.insert(children, w.Container({
			margin = p.EdgeInsets.only({top = 8}),
			padding = p.EdgeInsets.all(12),
			decoration = p.BoxDecoration({color = CARD, borderRadius = p.BorderRadius.circular(10), border = p.Border.all({color = LINE})}),
			child = w.Row({children = {
				w.Expanded({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = {
					txt(if item then item.name else "Weekly booster", 12, INK, ui.FontWeight.w800),
					txt(string.format("%g× · 7 days · not activated", if item then item.multiplier or 1 else 1), 11, MUTED),
					if why then txt(why, 10, NOTICE, nil, 2) else w.SizedBox.shrink({}),
				}})}),
				gap(8),
				button("Activate", if why or not shop:ready() then nil else function() shop:showDialog({ kind = "activate", token = token.id }) end,
					false, "shop-activate-" .. token.id),
			}}),
		}))
	end
	table.insert(children, gap(12))
	table.insert(children, txt("Boosts apply to mini-game completion and performance rewards only. They do not stack, and never increase Stars, refunds or grants. Weekly timers continue while you are offline.",
		10, MUTED, nil, 5))
	return w.Container({
		margin = p.EdgeInsets.only({top = 20}),
		padding = p.EdgeInsets.only({top = 14}),
		decoration = p.BoxDecoration({border = p.Border({top = p.BorderSide({color = LINE})})}),
		child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = children}),
	})
end

local function catalogue(shop: Controller.Controller, clock: () -> number, frozen: boolean): w.Widget
	local items = shop:items()
	local category = shop.category
	local children: {w.Widget} = {
		w.Row({crossAxisAlignment = w.CrossAxisAlignment.start, children = {
			w.Expanded({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = {
				txt(Shop.TITLES[category], 14, INK, ui.FontWeight.w900),
				gap(3),
				txt(Shop.BLURBS[category], 10, MUTED, nil, 3),
			}})}),
			gap(8),
			txt(#items .. " options", 10, MUTED),
		}}),
		gap(10),
	}
	if category == "boosters" then
		table.insert(children, boostSummary(shop))
	else
		table.insert(children, filters(shop))
		table.insert(children, gap(11))
	end
	table.insert(children, grid(shop, clock, frozen, items))
	if category == "boosters" then table.insert(children, inventory(shop)) end
	return w.Padding({padding = p.EdgeInsets.fromLTRB(14, 14, 14, 20),
		child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = children})})
end

-- Footer ---------------------------------------------------------------

local function footer(shop: Controller.Controller): w.Widget
	local item = Shop.get(shop.selected)
	local account = shop.account
	if not item or not account then return w.SizedBox.shrink({}) end
	local owned = Shop.owned(account, item)
	local equipped = shop:isEquipped(item)
	local why = if owned then nil else shop:reason(item)
	local tokens = 0
	for _, token in account.tokens do if token.item == item.id then tokens += 1 end end
	local info: {w.Widget} = {
		txt(item.name, 12, INK, ui.FontWeight.w800),
		gap(3),
		txt(if item.category == "names" then "Name text only · plate sold separately"
			elseif item.category == "plates" then "Nameplate only · colour equipped separately" else item.description, 10, MUTED, nil, 3),
	}
	if why then table.insert(info, gap(3)); table.insert(info, txt(why, 9, NOTICE, nil, 2)) end
	if tokens > 0 then table.insert(info, gap(3)); table.insert(info, txt(tokens .. " unused activation token" .. (if tokens == 1 then "" else "s"), 9, NOTICE)) end
	if shop.unavailable then table.insert(info, gap(3)); table.insert(info, txt("Your account couldn't be refreshed. Purchases are paused.", 9, color(0xffffb5c0), nil, 2)) end
	local working = shop.working ~= nil
	local label: w.Widget | string
	local action: (() -> ())? = nil
	if working then
		label = "Processing…"
	elseif owned then
		label = if item.category == "boosters" then "Owned" elseif equipped then "Equipped" else "Equip"
		if item.category ~= "boosters" and not equipped and shop:ready() then action = function() shop:act() end end
	else
		local cost = Shop.cost(account, item)
		local upgrade = item.permanent and account.permanent == 1.5 and item.multiplier == 2
		label = w.Row({mainAxisSize = w.MainAxisSize.min, children = {
			txt(if upgrade then "Upgrade · " else "Buy · ", 12, ON_ACCENT, ui.FontWeight.w800),
			money(cost, item.currency, 11, ON_ACCENT, false),
		}})
		if not why and shop:ready() then action = function() shop:act() end end
	end
	return w.Container({
		padding = p.EdgeInsets.fromLTRB(13, 11, 13, 11),
		decoration = p.BoxDecoration({color = FOOTER, border = p.Border({top = p.BorderSide({color = color(0xff3a3051)})})}),
		child = w.Row({children = {
			w.Expanded({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = info})}),
			gap(10),
			w.ConstrainedBox({constraints = r.BoxConstraints({minWidth = 135}), child = button(label, action, true, "shop-action")}),
		}}),
	})
end

-- Dialogs --------------------------------------------------------------

local function row(left: string, right: w.Widget | string): w.Widget
	return w.Container({
		padding = p.EdgeInsets.symmetric({vertical = 10}),
		decoration = p.BoxDecoration({border = p.Border({bottom = p.BorderSide({color = color(0xff3a3051)})})}),
		child = w.Row({children = {
			w.Expanded({child = txt(left, 12, MUTED)}),
			if type(right) == "string" then txt(right, 12, INK, ui.FontWeight.w700) else right,
		}}),
	})
end

local function dialogFrame(shop: Controller.Controller, title: string, body: {w.Widget}, actions: {w.Widget}, closable: boolean): w.Widget
	local children: {w.Widget} = {
		w.Row({children = {
			w.Expanded({child = txt(title, 20, INK, ui.FontWeight.w900)}),
			if closable then iconButton(material.close_rounded, "Close", function() shop:showDialog(nil) end, "shop-dialog-close") else w.SizedBox.shrink({}),
		}}),
		gap(10),
	}
	for _, part in body do table.insert(children, part) end
	if #actions > 0 then
		local buttons: {w.Widget} = {}
		for i, action in actions do
			if i > 1 then table.insert(buttons, gap(9)) end
			table.insert(buttons, w.Expanded({child = action}))
		end
		table.insert(children, gap(18))
		table.insert(children, w.Row({children = buttons}))
	end
	-- The dialog keeps the keyboard's focus while it is open.
	return w.FocusScope({autofocus = true, child = w.Container({
		constraints = r.BoxConstraints({maxWidth = 405}),
		padding = p.EdgeInsets.all(19),
		decoration = p.BoxDecoration({color = DIALOG, borderRadius = p.BorderRadius.circular(18), border = p.Border.all({color = DIALOG_EDGE}),
			boxShadow = { p.BoxShadow({color = color(0x55000000), blurRadius = 40, offset = ui.Offset({dx = 0, dy = 20})}) }}),
		child = w.SingleChildScrollView({child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min,
			children = children})}),
	})})
end

local function paragraph(text: string): w.Widget
	return w.Padding({padding = p.EdgeInsets.symmetric({vertical = 4}), child = txt(text, 12, MUTED, nil, 8)})
end

local function confirmDialog(shop: Controller.Controller, id: string): w.Widget?
	local item, account = Shop.get(id), shop.account
	if not item or not account then return nil end
	local cost = Shop.cost(account, item)
	local refunds = Shop.refunds(account, item)
	local refund = Shop.refundTotal(refunds)
	local balance = shop:balance(item.currency)
	local after = if balance then balance - cost + (if item.currency == "stars" then refund else 0) else nil
	local body: {w.Widget} = { paragraph(item.name .. " — " .. item.description), row("Price", money(cost, item.currency, 12)) }
	if item.permanent and cost ~= item.price then table.insert(body, row("Upgrade from Eternal Radiance", "−" .. Style.count(item.price - cost) .. " Stars")) end
	table.insert(body, row("Current balance", if balance then money(balance, item.currency, 12) else "—"))
	if refund > 0 then
		table.insert(body, row(#refunds .. " unused weekly token" .. (if #refunds == 1 then "" else "s") .. " refunded", "+" .. Style.count(refund) .. " Stars"))
	end
	table.insert(body, row("Balance after purchase", if after then money(math.max(0, after), item.currency, 12) else "—"))
	table.insert(body, paragraph(if Shop.isWeekly(item)
		then "You receive an activation token. The seven-day timer starts only when you activate it, then runs for seven consecutive days, including time offline."
		elseif item.permanent then "Permanent booster, applied at once. Only the highest active multiplier applies."
		else "Permanent cosmetic, saved to your account. You can equip it after purchase."))
	local working = shop.working ~= nil
	return dialogFrame(shop, "Confirm purchase", body, {
		button("Cancel", if working then nil else function() shop:showDialog(nil) end, false, "shop-cancel"),
		button(if working then "Processing…" else "Confirm purchase", if working or not shop:ready() then nil else function() shop:confirm() end,
			true, "shop-confirm", true),
	}, not working)
end

local function boughtDialog(shop: Controller.Controller, id: string): w.Widget?
	local item = Shop.get(id)
	if not item then return nil end
	return dialogFrame(shop, "It's yours", { paragraph(item.name .. " is now in your collection. Your equipped look is unchanged.") }, {
		button("Keep browsing", function() shop:showDialog(nil) end, false, "shop-keep-browsing"),
		button("Equip now", if shop:ready() then function() shop:showDialog(nil); shop:equip(id) end else nil, true, "shop-equip-now", true),
	}, true)
end

local function activateDialog(shop: Controller.Controller, tokenId: string): w.Widget?
	local account = shop.account
	if not account then return nil end
	local token: Shop.Token? = nil
	for _, t in account.tokens do if t.id == tokenId then token = t end end
	local item = if token then Shop.get(token.item) else nil
	if not token or not item then return nil end
	local working = shop.working ~= nil
	return dialogFrame(shop, "Activate booster?", {
		paragraph(string.format("%s · %g× Starlight", item.name, item.multiplier or 1)),
		paragraph("Activating now starts seven consecutive days. The timer keeps running while you are offline."),
		row("Expires", expiry(shop:now() + Shop.WEEK)),
		paragraph("Boosters don't stack: your highest multiplier applies."),
	}, {
		button("Not yet", if working then nil else function() shop:showDialog(nil) end, false, "shop-not-yet"),
		button(if working then "Activating…" else "Activate for 7 days", if working then nil else function() shop:activate(tokenId) end,
			true, "shop-confirm-activate", true),
	}, not working)
end

local function toggle(label: string, on: boolean, onTap: () -> (), key: string): w.Widget
	return Pressable({key = w.ValueKey({value = key}), focusable = true, radius = 8, depth = 0.02, label = label, selected = on, onTap = onTap,
		child = w.Padding({padding = p.EdgeInsets.symmetric({vertical = 8}), child = w.Row({children = {
			w.Icon({icon = if on then material.check_box_rounded else material.check_box_outline_blank_rounded, size = 22,
				color = if on then ACCENT else MUTED}),
			gap(10),
			w.Expanded({child = txt(label, 12, INK, ui.FontWeight.w600, 2)}),
		}})})})
end

local function settingsDialog(shop: Controller.Controller): w.Widget
	local prefs = shop:prefs()
	return dialogFrame(shop, "Settings", {
		toggle("Reduce motion", prefs.motion, function() shop:setPrefs(not prefs.motion, prefs.effects) end, "shop-pref-motion"),
		toggle("Reduce cosmetic glow and effects", prefs.effects, function() shop:setPrefs(prefs.motion, not prefs.effects) end, "shop-pref-effects"),
		paragraph("These change only how cosmetics look for you. Your items and saved look stay the same."),
	}, { button("Purchase history", function() shop:showDialog({ kind = "history" }) end, false, "shop-history", true) }, true)
end

local HISTORY_KINDS: {[string]: string} = { purchase = "Purchased", refund = "Refunded", activation = "Activated", reward = "Mini-game reward",
	grant = "Admin test grant" }

local function historyDialog(shop: Controller.Controller): w.Widget
	local account = shop.account
	local body: {w.Widget} = {}
	if not account or #account.history == 0 then
		table.insert(body, paragraph("No transactions yet."))
	else
		for _, h in account.history do
			local item = if h.item then Shop.get(h.item) else nil
			local what = HISTORY_KINDS[h.kind] .. (if item then " · " .. item.name else "")
			local amount = if h.kind == "activation" then "" elseif h.kind == "purchase" then "−" .. Style.count(h.amount) .. " " .. Shop.currencyName(h.currency)
				else "+" .. Style.count(h.amount) .. " " .. Shop.currencyName(h.currency)
			table.insert(body, w.Container({
				padding = p.EdgeInsets.symmetric({vertical = 9}),
				decoration = p.BoxDecoration({border = p.Border({bottom = p.BorderSide({color = LINE})})}),
				child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.start, mainAxisSize = w.MainAxisSize.min, children = {
					txt(what, 12, INK, ui.FontWeight.w700),
					txt(expiry(h.at) .. (if amount ~= "" then " · " .. amount else ""), 10, MUTED),
				}}),
			}))
		end
	end
	return dialogFrame(shop, "Purchase history", body, { button("Back", function() shop:showDialog({ kind = "settings" }) end, false, "shop-history-back", true) }, true)
end

-- Admin test tools -----------------------------------------------------

local function heading(text: string): w.Widget
	return w.Padding({padding = p.EdgeInsets.only({top = 12, bottom = 6}), child = txt(text, 11, GOLD, ui.FontWeight.w800)})
end

-- A row of small buttons.
local function tools(buttons: {{any}}): w.Widget
	local row: {w.Widget} = {}
	for i, b in buttons do
		if i > 1 then table.insert(row, gap(6)) end
		table.insert(row, w.Expanded({child = button(b[1] :: string, b[2] :: (() -> ())?, false, "shop-test-" .. (b[3] :: string))}))
	end
	return w.Row({children = row})
end

local FAULTS: {{string}} = {
	{ "none", "Normal" }, { "refuse", "Refused: not enough Stars" },
	{ "unknown", "Unknown answer: stays pending, settles on retry" }, { "deliver", "Charged, delivery fails once, then delivers" },
}

local function testsDialog(shop: Controller.Controller): w.Widget
	local tester = shop.tester
	if not tester then return paragraph("Admins only.") end
	local fault = tester.fault
	local faults: {w.Widget} = {}
	for _, entry in FAULTS do
		local key, label = entry[1], entry[2]
		local on = fault == key
		table.insert(faults, Pressable({key = w.ValueKey({value = "shop-test-fault-" .. key}), focusable = true, radius = 8, depth = 0.02,
			label = label, selected = on, onTap = function() shop:test("fault", key) end,
			child = w.Padding({padding = p.EdgeInsets.symmetric({vertical = 5}), child = w.Row({children = {
				w.Icon({icon = if on then material.radio_button_checked_rounded else material.radio_button_unchecked_rounded, size = 18,
					color = if on then ACCENT else MUTED}),
				gap(8),
				w.Expanded({child = txt(label, 11, INK, nil, 2)}),
			}})})}))
	end
	local body: {w.Widget} = {
		paragraph("Admins only. These change your own account (and the leaderboard, for Starlight)."),
		heading("BALANCES"),
		tools({ { "+1,000 Starlight", function() shop:test("grant", 1000) end, "grant-1k" },
			{ "+10,000 Starlight", function() shop:test("grant", 10000) end, "grant-10k" } }),
		gap(6),
		tools({ { "+20,000 test Stars", if tester.sandbox then function() shop:testStars(20000) end else nil, "stars" },
			{ "Starlight to 0", function() shop:test("zero") end, "zero" } }),
		if tester.sandbox then w.SizedBox.shrink({}) else txt("Test Stars work only in editor Play: real Stars are never granted.", 10, NOTICE, nil, 2),
		heading("MINI-GAME REWARDS (BOOSTED LIKE REAL ONES)"),
		tools({ { "1st place: 100", function() shop:test("reward", "first") end, "reward-first" },
			{ "Completion: 50", function() shop:test("reward", "complete") end, "reward-complete" } }),
		gap(6),
		tools({ { "Repeat last reward (no effect)", function() shop:test("repeat_reward", "first") end, "reward-repeat" } }),
		heading("NEXT STARS PURCHASE"),
	}
	for _, f in faults do table.insert(body, f) end
	table.insert(body, heading("BOOSTERS"))
	table.insert(body, tools({ { "End weekly now", function() shop:test("expire") end, "expire" },
		{ "Ends in 1 minute", function() shop:test("expire_soon") end, "expire-soon" } }))
	table.insert(body, heading("ACCOUNT"))
	table.insert(body, tools({ { "Reset my shop account…", function() shop:showDialog({ kind = "reset" }) end, "reset" } }))
	return dialogFrame(shop, "Test tools", body, {}, true)
end

local function resetDialog(shop: Controller.Controller): w.Widget
	return dialogFrame(shop, "Reset your shop account?", {
		paragraph("Removes everything you own and wear, your booster tokens, running booster, permanent tier, settings and history. Your Starlight stays. This can't be undone."),
	}, {
		button("Cancel", function() shop:showDialog({ kind = "tests" }) end, false, "shop-reset-cancel", true),
		button("Reset", function() shop:test("reset"); shop:showDialog({ kind = "tests" }) end, true, "shop-reset-confirm"),
	}, true)
end

local function pendingDialog(shop: Controller.Controller, message: string): w.Widget
	return dialogFrame(shop, "Purchase pending", {
		paragraph(message),
		paragraph("We'll finish it for you — the item is delivered once, or nothing is charged. You can close the shop; we'll let you know."),
	}, { button("OK", function() shop:showDialog(nil) end, true, "shop-pending-ok", true) }, true)
end

local function dialogOf(shop: Controller.Controller): w.Widget?
	local dialog = shop.dialog
	if not dialog then return nil end
	if dialog.kind == "confirm" then return confirmDialog(shop, dialog.item)
	elseif dialog.kind == "bought" then return boughtDialog(shop, dialog.item)
	elseif dialog.kind == "activate" then return activateDialog(shop, dialog.token)
	elseif dialog.kind == "pending" then return pendingDialog(shop, dialog.message)
	elseif dialog.kind == "history" then return historyDialog(shop)
	elseif dialog.kind == "tests" then return testsDialog(shop)
	elseif dialog.kind == "reset" then return resetDialog(shop)
	end
	return settingsDialog(shop)
end

-- States before the account comes, or when it cannot.
local function waiting(shop: Controller.Controller): w.Widget
	if shop.unavailable then
		return w.Padding({padding = p.EdgeInsets.all(28), child = w.Column({mainAxisAlignment = w.MainAxisAlignment.center, children = {
			txt("Your account couldn't be loaded", 15, INK, ui.FontWeight.w800, 2, ui.TextAlign.center),
			gap(8),
			txt("Purchases are disabled until it loads. Nothing in your collection has changed.", 12, MUTED, nil, 4, ui.TextAlign.center),
			gap(16),
			button("Try again", function() shop:retry() end, true, "shop-retry", true),
		}})})
	end
	return w.Center({child = w.Column({mainAxisSize = w.MainAxisSize.min, children = {
		w.SizedBox({width = 22, height = 22, child = m.CircularProgressIndicator({strokeWidth = 2, color = ACCENT})}),
		gap(12),
		txt("Loading your account…", 12, MUTED),
	}})})
end

return define("ShopPanel", {
	createState = function(): Fields return { unlisten = nil, scroll = nil } end,
	initState = function(self: State)
		self.scroll = w.ScrollController({})
		self.unlisten = self.widget.shop:listen(function()
			if self.mounted then self:setState(function() end) end
		end)
	end,
	dispose = function(self: State)
		if self.unlisten then self.unlisten(); self.unlisten = nil end
		if self.scroll then self.scroll:dispose() end
	end,
	build = function(self: State, context: w.BuildContext): w.Widget
		local shop, clock = self.widget.shop, self.widget.clock
		if not shop.open then return w.SizedBox.shrink({}) end
		local frozen = still(shop, context)
		local name = shop.name or "You"
		local body: w.Widget
		if shop.account then
			local parts: {w.Widget} = {}
			if shop.category ~= "boosters" then table.insert(parts, preview(shop, clock, frozen, name)) end
			table.insert(parts, catalogue(shop, clock, frozen))
			body = w.Expanded({child = w.SingleChildScrollView({controller = self.scroll,
				child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, mainAxisSize = w.MainAxisSize.min, children = parts})})})
		else
			body = w.Expanded({child = waiting(shop)})
		end
		local dialog = dialogOf(shop)
		local shell = w.Container({
			constraints = r.BoxConstraints({maxWidth = MAX_WIDTH, maxHeight = 940}),
			decoration = p.BoxDecoration({color = PANEL, borderRadius = p.BorderRadius.circular(20), border = p.Border.all({color = PANEL_EDGE}),
				boxShadow = { p.BoxShadow({color = color(0x55100a30), blurRadius = 70, offset = ui.Offset({dx = 0, dy = 18})}) }}),
			clipBehavior = ui.Clip.antiAlias,
			child = w.Column({crossAxisAlignment = w.CrossAxisAlignment.stretch, children = {
				header(shop),
				body,
				if shop.account then footer(shop) else w.SizedBox.shrink({}),
			}}),
		})
		local layers: {w.Widget} = {
			-- The lobby dims behind the shop; taps stay in the shop.
			w.GestureDetector({behavior = r.HitTestBehavior.opaque, onTap = function() end, child = w.Container({color = DIM})}),
			w.SafeArea({child = w.Padding({padding = p.EdgeInsets.fromLTRB(12, 12, 12, 12), child = w.Center({
				-- Behind an open dialog, nothing takes focus.
				child = w.Focus({canRequestFocus = false, descendantsAreFocusable = dialog == nil, child = shell})})})}),
		}
		if dialog then
			table.insert(layers, w.GestureDetector({behavior = r.HitTestBehavior.opaque,
				onTap = function() if shop.working == nil then shop:showDialog(nil) end end, child = w.Container({color = SCRIM})}))
			table.insert(layers, w.SafeArea({child = w.Center({child = w.Padding({padding = p.EdgeInsets.all(18),
				child = w.GestureDetector({onTap = function() end, child = dialog})})})}))
		end
		local toast = shop.toast
		if toast then
			table.insert(layers, w.Positioned({left = 0, right = 0, bottom = 22, child = w.SafeArea({child = w.Center({child = w.Padding({
				padding = p.EdgeInsets.symmetric({horizontal = 16}),
				child = w.Container({
					constraints = r.BoxConstraints({maxWidth = 423}),
					padding = p.EdgeInsets.symmetric({horizontal = 19, vertical = 12}),
					decoration = p.BoxDecoration({color = TOAST, borderRadius = p.BorderRadius.circular(11),
						boxShadow = { p.BoxShadow({color = color(0x55000000), blurRadius = 25, offset = ui.Offset({dx = 0, dy = 8})}) }}),
					child = w.Semantics({liveRegion = true, child = txt(toast, 12, TOAST_INK, ui.FontWeight.w700, 3, ui.TextAlign.center)}),
				})})})})}))
		end
		return w.Stack({fit = w.StackFit.expand, children = layers})
	end,
})
