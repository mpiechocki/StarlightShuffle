--!strict
--@client
-- The lobby shop's state (widgets/ShopPanel draws it): the account the
-- server last sent (shared/Shop; nil until it comes, `unavailable` when it
-- could not be read, which keeps purchases off), the tab, filter and selected
-- item, the look being previewed, the open dialog, and the one request in
-- flight. Selecting an item previews it and never buys or equips it; closing
-- the shop drops the preview. Everything that changes the account is asked
-- of the server (server/Accounts), which answers SHOPPED and a fresh ACCOUNT;
-- a purchase shows "Processing…" until it is done, and a payment the platform
-- has not confirmed stays pending (never offered again) until it settles.
--
-- Stars are the app's: the balance is the signed-in account's as the app gave
-- it, less what the shop spent in this session (plus refunds).
--
-- Admins (the server sends them TESTER) also get the shop's test tools
-- (widgets/ShopPanel's "Test tools"); the server checks every use. Test Stars
-- exist only where the economy is the stand-in (editor Play), and only in this
-- shop's balance: real Stars are never granted.
local client = require("@moonbase/client")
local game = require("@moonbase/game")
local session = require("@es/session")
local foundation = require("@flutter/foundation")
local Net = require("../shared/Net")
local Shop = require("../shared/Shop")
local Looks = require("./Looks")

local TOAST_FOR = 4.2 -- seconds a toast shows

export type Dialog =
	{ kind: "confirm", item: string }
	| { kind: "bought", item: string, refund: number }
	| { kind: "activate", token: string }
	| { kind: "pending", message: string }
	| { kind: "history" }
	| { kind: "settings" }
	| { kind: "tests" }
	| { kind: "reset" }
-- The request in flight: what it is for, as confirmed.
type Working = { request: string, kind: "buy" | "equip" | "activate", item: string?, price: number, currency: Shop.Currency?,
	refund: number, slot: Shop.Slot?, unequip: boolean }

type Fields = {
	account: Shop.Account?, unavailable: boolean,
	-- game.clock() when the account came, to tell the datastore's time since.
	readAt: number,
	open: boolean,
	category: Shop.Category, filter: Shop.Filter, selected: string,
	preview: Shop.Look,
	-- The outfit and name the preview shows (ours, as the shop opened).
	outfit: {number}?, name: string?,
	dialog: Dialog?,
	working: Working?,
	toast: string?, toastAt: number,
	starsBase: number?, starsSpent: number,
	-- Admins only: whether Stars are the stand-in's, and the next Stars purchase's test fault.
	tester: { sandbox: boolean, fault: Shop.Fault }?,
	-- Ticks animated samples while the shop is open (widgets/Cosmetics).
	frame: foundation.ChangeNotifier,
	time: number,
	-- The minute last told to listeners, so booster countdowns move.
	minute: number,
	serial: number,
	listeners: {() -> ()},
	unsubscribe: (() -> ())?,
}
local Controller = {}
Controller.__index = Controller
export type Controller = typeof(setmetatable({} :: Fields, Controller))

local function changed(self: Controller)
	for _, listener in table.clone(self.listeners) do listener() end
end

local function toast(self: Controller, message: string)
	self.toast, self.toastAt = message, game.clock()
end

local function look(self: Controller): Shop.Look
	local account = self.account
	return if account then table.clone(account.equipped) else Shop.defaultLook()
end

local function setSlot(preview: Shop.Look, slot: Shop.Slot, id: string)
	if slot == "names" then preview.names = id elseif slot == "plates" then preview.plates = id else preview.glows = id end
end

function Controller.new(): Controller
	local base = session.user.main_currency
	local self = setmetatable({
		account = nil, unavailable = false, readAt = 0, open = false, category = "names", filter = "all",
		selected = Shop.DEFAULTS.names, preview = Shop.defaultLook(), outfit = nil, name = nil, dialog = nil, working = nil,
		toast = nil, toastAt = 0, starsBase = if type(base) == "number" and base >= 0 then math.floor(base) else nil,
		starsSpent = 0, tester = nil, frame = foundation.ChangeNotifier(), time = 0, minute = -1, serial = 0, listeners = {}, unsubscribe = nil,
	} :: Fields, Controller)
	self.unsubscribe = client.onMessage(function(kind: unknown, a: unknown, ...: unknown)
		if kind == Net.ACCOUNT then
			local account = Shop.account(a)
			if account then
				local first = self.account == nil
				self.account, self.unavailable, self.readAt = account, false, game.clock()
				if first then self.preview = look(self) end
				changed(self)
			elseif a == false then
				-- Never shown as empty: what was read before stays, purchases go off.
				self.unavailable = true
				changed(self)
			end
		elseif kind == Net.TESTER then
			local r = if type(a) == "table" then a :: {[string]: unknown} else nil
			local fault = if r then Shop.fault(r.fault) else nil
			if r and fault and type(r.sandbox) == "boolean" then
				self.tester = { sandbox = r.sandbox :: boolean, fault = fault }
				changed(self)
			end
		elseif kind == Net.STARLIGHTS then
			local total, account = Net.starlights(a), self.account
			if total and account then account.starlight = total; changed(self) end
		elseif kind == Net.SHOPPED then
			local outcome, message, refund = ...
			if type(a) ~= "string" or type(outcome) ~= "string" then return end
			self:settled(a, outcome, if type(message) == "string" then message else "",
				if type(refund) == "number" and refund >= 0 then math.floor(refund) else 0)
		end
	end)
	return self
end

function Controller.listen(self: Controller, listener: () -> ()): () -> ()
	table.insert(self.listeners, listener)
	return function()
		local at = table.find(self.listeners, listener)
		if at then table.remove(self.listeners, at) end
	end
end

-- The datastore's clock now, in milliseconds.
function Controller.now(self: Controller): number
	local account = self.account
	return if account then account.now + math.floor((game.clock() - self.readAt) * 1000) else 0
end

-- The Stars balance as far as this session knows it; nil when the app gave none.
function Controller.stars(self: Controller): number?
	local base = self.starsBase
	return if base then math.max(0, base - self.starsSpent) else nil
end

function Controller.balance(self: Controller, currency: Shop.Currency): number?
	if currency == "stars" then return self:stars() end
	local account = self.account
	return if account then account.starlight else nil
end

-- Whether buying is possible at all: an account read, and nothing in flight.
function Controller.ready(self: Controller): boolean
	return self.account ~= nil and not self.unavailable and self.working == nil
end

-- The visible items of the current tab, sorted.
function Controller.items(self: Controller): {Shop.Item}
	local account = self.account
	if not account then return {} end
	return Shop.visible(account, self.category, self.filter)
end

-- Why the selected item cannot be bought now (nil when it can).
function Controller.reason(self: Controller, item: Shop.Item): string?
	local account = self.account
	if not account then return "Your account is loading." end
	return Shop.reason(account, item, self:now(), self:stars())
end

function Controller.isEquipped(self: Controller, item: Shop.Item): boolean
	local account = self.account
	return account ~= nil and item.category ~= "boosters" and Shop.slot(account.equipped, item.category :: Shop.Slot) == item.id
end

-- Whether the preview shows the saved look.
function Controller.saved(self: Controller): boolean
	local equipped = look(self)
	return equipped.names == self.preview.names and equipped.plates == self.preview.plates and equipped.glows == self.preview.glows
end

local function request(self: Controller): string
	self.serial += 1
	return string.format("r%x%x%x", self.serial, math.floor(game.clock() * 1000) % 0xffffff, math.random(0, 0xffffff))
end

function Controller.openShop(self: Controller, outfit: {number}, name: string?)
	if self.open then return end
	self.open, self.dialog, self.outfit, self.name = true, nil, outfit, name
	self.category, self.filter = "names", "all"
	self.preview = look(self)
	self.selected = self.preview.names
	client.notifyServer(Net.SHOP)
	changed(self)
end

-- Asks for the account again after it could not be read.
function Controller.retry(self: Controller)
	self.unavailable = false
	client.notifyServer(Net.SHOP)
	changed(self)
end

-- Closes the shop; an uncommitted preview goes with it.
function Controller.close(self: Controller)
	if not self.open then return end
	self.open, self.dialog = false, nil
	self.preview = look(self)
	changed(self)
end

function Controller.setCategory(self: Controller, category: Shop.Category)
	self.category, self.filter = category, "all"
	local first = self:items()[1]
	if category ~= "boosters" then
		-- Its tab opens on what is worn there.
		self.selected = Shop.slot(self.preview, category :: Shop.Slot)
	elseif first then
		self.selected = first.id
	end
	changed(self)
end

function Controller.setFilter(self: Controller, filter: Shop.Filter)
	self.filter = filter
	local list = self:items()
	local listed = false
	for _, item in list do if item.id == self.selected then listed = true end end
	if not listed and list[1] then self:select(list[1].id) else changed(self) end
end

-- Previews [id]; never buys or equips it.
function Controller.select(self: Controller, id: string)
	local item = Shop.get(id)
	if not item then return end
	self.selected = id
	if item.category ~= "boosters" then setSlot(self.preview, item.category :: Shop.Slot, id) end
	changed(self)
end

function Controller.resetPreview(self: Controller)
	self.preview = look(self)
	changed(self)
end

function Controller.showDialog(self: Controller, dialog: Dialog?)
	self.dialog = dialog
	changed(self)
end

-- The footer's button: equip what is owned, or ask to confirm a purchase.
function Controller.act(self: Controller)
	local item = Shop.get(self.selected)
	local account = self.account
	if not item or not account or self.working then return end
	if Shop.owned(account, item) then
		if item.category ~= "boosters" and not self:isEquipped(item) then self:equip(item.id) end
		return
	end
	local why = self:reason(item)
	if why then toast(self, why); changed(self); return end
	self:showDialog({ kind = "confirm", item = item.id })
end

-- Buys the item the confirmation shows, at the price it showed.
function Controller.confirm(self: Controller)
	local dialog = self.dialog
	local account = self.account
	if not dialog or dialog.kind ~= "confirm" or not account or not self:ready() then return end
	local item = Shop.get(dialog.item)
	if not item then return end
	local price = Shop.cost(account, item)
	local id = request(self)
	self.working = { request = id, kind = "buy", item = item.id, price = price, currency = item.currency,
		refund = Shop.refundTotal(Shop.refunds(account, item)), slot = nil, unequip = false }
	client.notifyServer(Net.BUY, id, item.id, price, item.currency)
	changed(self)
end

-- Equips [id] (owned), saving it at once.
function Controller.equip(self: Controller, id: string, unequip: boolean?)
	local item = Shop.get(id)
	if not item or item.category == "boosters" or not self:ready() then return end
	local slot = item.category :: Shop.Slot
	local rid = request(self)
	self.working = { request = rid, kind = "equip", item = id, price = 0, currency = nil, refund = 0, slot = slot, unequip = unequip == true }
	client.notifyServer(Net.EQUIP, rid, slot, id)
	changed(self)
end

function Controller.unequip(self: Controller, slot: Shop.Slot)
	self:equip(Shop.slot(Shop.defaultLook(), slot), true)
end

-- Starts the booster [token] the activation dialog shows.
function Controller.activate(self: Controller, token: string)
	if not self:ready() then return end
	local rid = request(self)
	self.working = { request = rid, kind = "activate", item = nil, price = 0, currency = nil, refund = 0, slot = nil, unequip = false }
	client.notifyServer(Net.ACTIVATE, rid, token)
	changed(self)
end

function Controller.setPrefs(self: Controller, motion: boolean, effects: boolean)
	local account = self.account
	if not account then return end
	account.prefs = { motion = motion, effects = effects }
	client.notifyServer(Net.PREFS, motion, effects)
	changed(self)
end

-- Admins: runs test tool [action] (Shop.TESTS) on the server.
function Controller.test(self: Controller, action: string, argument: (string | number)?)
	if not self.tester or not Shop.TESTS[action] then return end
	if argument ~= nil then client.notifyServer(Net.SHOP_TEST, action, argument) else client.notifyServer(Net.SHOP_TEST, action) end
end

-- Admins, in editor Play only: [amount] test Stars in this shop's balance.
function Controller.testStars(self: Controller, amount: number)
	local tester = self.tester
	if not tester or not tester.sandbox then return end
	self.starsBase = (self.starsBase or 0)
	self.starsSpent -= amount
	toast(self, "Admin test: +" .. amount .. " test Stars (editor Play only, nothing real).")
	changed(self)
end

function Controller.prefs(self: Controller): Shop.Prefs
	local account = self.account
	return if account then account.prefs else { motion = false, effects = false }
end

-- How request [id] went (SHOPPED).
function Controller.settled(self: Controller, id: string, outcome: string, message: string, refund: number)
	local working = self.working
	-- A purchase settled later (after a reconnect, or a pending one) has no request.
	local mine = working ~= nil and (working.request == id or (id == "" and working.kind == "buy"))
	if not working or not mine then
		if message ~= "" then toast(self, message) end
		if id == "" and outcome == "done" and self.dialog and self.dialog.kind == "pending" then self.dialog = nil end
		changed(self)
		return
	end
	if outcome == "pending" then
		-- Still settling: the button stays "Processing…", and says why if the platform is slow.
		if message ~= "" then self.dialog = { kind = "pending", message = message } end
		changed(self)
		return
	end
	self.working = nil
	if outcome == "refused" then
		if self.dialog and (self.dialog.kind == "confirm" or self.dialog.kind == "activate") then self.dialog = nil end
		toast(self, if message ~= "" then message else "That didn't work. Nothing was charged.")
		changed(self)
		return
	end
	if working.kind == "buy" then
		local item = Shop.get(working.item)
		if working.currency == "stars" then self.starsSpent += working.price - refund end
		if item and item.category == "boosters" then
			self.dialog = nil
			toast(self, if item.permanent then (if refund > 0 then "Permanent booster saved. " .. refund .. " Stars refunded for unused tokens."
				else "Permanent booster saved.") else "Booster token saved. Activate it from Your boosters.")
		elseif item then
			self.dialog = { kind = "bought", item = item.id, refund = refund }
		end
	elseif working.kind == "equip" then
		if working.slot and working.item then setSlot(self.preview, working.slot, working.item) end
		toast(self, if working.unequip then "Unequipped and saved." else "Equipped and saved.")
	else
		self.dialog = nil
		toast(self, "Booster activated and saved.")
	end
	changed(self)
end

-- Whether anything the shop shows moves now (it ticks while it does).
local function animating(self: Controller): boolean
	if not self.open or self:prefs().motion then return false end
	if self.category == "names" or self.category == "plates" then return true end
	return Looks.moving(self.preview.names, self.preview.plates)
end

function Controller.update(self: Controller, dt: number)
	self.time += dt
	if animating(self) then self.frame:notifyListeners() end
	local dirty = false
	if self.toast and game.clock() - self.toastAt > TOAST_FOR then self.toast = nil; dirty = true end
	local minute = math.floor(self:now() / 60000)
	if self.open and minute ~= self.minute then self.minute = minute; dirty = true end
	if dirty then changed(self) end
end

-- Another place: no shop there (its account comes again in the next lobby).
function Controller.transferred(self: Controller)
	self:close()
end

function Controller.dispose(self: Controller)
	if self.unsubscribe then self.unsubscribe(); self.unsubscribe = nil end
	table.clear(self.listeners)
	self.frame:dispose()
end

return Controller
