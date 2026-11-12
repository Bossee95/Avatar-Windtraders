--[[
	TradeEngine

	Player-to-player trading (GDD §8.3, §8.4, §16.4). Pure Lua: every Roblox dependency
	is injected, so the full flow is unit-tested outside Studio.

	Flow:
		Request(from, to)            -> trade in "Pending"
		Respond(to, id, true/false)  -> "Open" or closed as "Declined"
		SetOffer(player, id, items)  -> replaces that player's offer; clears both confirmations
		Confirm(player, id)          -> when both have confirmed: "Countdown"
		(countdown finishes)         -> re-validates everything, then applies the trade atomically
		Cancel(player, id)           -> either player, at any point before completion

	Validation, at every step and again just before applying:
		- both players are in an active PD (and the PD is not paused unless allowed)
		- both still have the same living character the trade started with
		- neither is combat-tagged (EconomyConfig.BlockTradeInCombat)
		- factions may trade (EconomyConfig.AllowCrossFactionTrade)
		- every offered item is in the offering character's carried inventory
		- every offered item is tradeable (not tagged Untradeable)
		- the trade is still in countdown and was not cancelled

	A trade can apply only once: finishing moves it to "Completed", and the countdown
	callback carries a token that is invalidated by any offer change or cancellation.

	Closed trades (completed or not) are written to TradeLog.
]]

local TradeEngine = {}
TradeEngine.__index = TradeEngine

TradeEngine.State = {
	Pending = "Pending",
	Open = "Open",
	Countdown = "Countdown",
	Completed = "Completed",
	Cancelled = "Cancelled",
	Declined = "Declined",
	Expired = "Expired",
}
local State = TradeEngine.State

local function noop() end

--[[
	deps:
		inventory           InventoryStore
		registry            ItemRegistry
		log                 TradeLog
		config              EconomyConfig
		now                 function(): number
		delay               function(seconds, fn): cancelFn
		getUserId           function(player): number
		getCharacterId      function(player): string?      nil if no living character
		getFaction          function(player): string?
		isTradingOpen       function(player): boolean       active PD check (pause handling done by caller)
		getPDEventId        function(): string?
		isInCombat          function(player): boolean       optional
		getDistance         function(a, b): number?         optional
		onUpdate            function(trade, eventName)      optional, to push state to clients
		newId               function(): string              optional
]]
function TradeEngine.new(deps)
	for _, key in ipairs({ "inventory", "registry", "log", "config", "now", "delay", "getUserId", "getCharacterId", "isTradingOpen" }) do
		assert(deps[key] ~= nil, "TradeEngine missing dependency " .. key)
	end
	local counter = 0
	return setmetatable({
		_d = deps,
		_cfg = deps.config,
		_newId = deps.newId or function()
			counter = counter + 1
			return "trade-" .. counter
		end,
		_onUpdate = deps.onUpdate or noop,
		_trades = {}, -- id -> trade
		_byPlayer = {}, -- player -> trade
	}, TradeEngine)
end

local function isClosed(trade)
	return trade.state == State.Completed
		or trade.state == State.Cancelled
		or trade.state == State.Declined
		or trade.state == State.Expired
end

function TradeEngine:GetTrade(tradeId)
	return self._trades[tradeId]
end

function TradeEngine:GetTradeForPlayer(player)
	return self._byPlayer[player]
end

function TradeEngine:_side(trade, player)
	if trade.a.player == player then
		return trade.a, trade.b
	elseif trade.b.player == player then
		return trade.b, trade.a
	end
	return nil
end

-- Checks that a single player is currently allowed to trade.
function TradeEngine:_checkPlayer(player)
	local d = self._d
	if not d.isTradingOpen(player) then
		return false, "NoActivePD"
	end
	if not d.getCharacterId(player) then
		return false, "NoLivingCharacter"
	end
	if self._cfg.BlockTradeInCombat and d.isInCombat and d.isInCombat(player) then
		return false, "InCombat"
	end
	return true
end

function TradeEngine:_checkPair(a, b)
	local ok, reason = self:_checkPlayer(a)
	if not ok then
		return false, reason
	end
	ok, reason = self:_checkPlayer(b)
	if not ok then
		return false, "Other" .. reason
	end
	local d = self._d
	if not self._cfg.AllowCrossFactionTrade and d.getFaction then
		if d.getFaction(a) ~= d.getFaction(b) then
			return false, "CrossFactionTradeDisabled"
		end
	end
	if self._cfg.TradeRange and d.getDistance then
		local dist = d.getDistance(a, b)
		if dist == nil or dist > self._cfg.TradeRange then
			return false, "TooFar"
		end
	end
	return true
end

-- Full re-check of a trade in progress: both players and both offers.
function TradeEngine:_checkTrade(trade)
	local ok, reason = self:_checkPair(trade.a.player, trade.b.player)
	if not ok then
		return false, reason
	end
	for _, side in ipairs({ trade.a, trade.b }) do
		if self._d.getCharacterId(side.player) ~= side.characterId then
			return false, "CharacterChanged"
		end
		ok, reason = self:_checkOffer(side, side.offer)
		if not ok then
			return false, reason
		end
	end
	return true
end

-- offer: array of { uid, quantity }
function TradeEngine:_checkOffer(side, offer)
	local inventory, registry = self._d.inventory, self._d.registry
	if #offer > (self._cfg.MaxItemsPerOffer or math.huge) then
		return false, "TooManyItems"
	end
	local from = inventory.Container.Character(side.characterId)
	local seen = {}
	for _, entry in ipairs(offer) do
		if seen[entry.uid] then
			return false, "DuplicateItem"
		end
		seen[entry.uid] = true
		local item = inventory:GetItem(entry.uid)
		if not item or item.container ~= from then
			return false, "NotOwner"
		end
		if not registry:IsTradeable(item.itemId) then
			return false, "Untradeable"
		end
		local q = entry.quantity
		if type(q) ~= "number" or q < 1 or q ~= math.floor(q) or q > item.quantity then
			return false, "InvalidQuantity"
		end
	end
	return true
end

local function copyOffer(offer)
	local out = {}
	for _, entry in ipairs(offer) do
		table.insert(out, { uid = entry.uid, quantity = entry.quantity })
	end
	return out
end

function TradeEngine:_newSide(player)
	return {
		player = player,
		userId = self._d.getUserId(player),
		characterId = self._d.getCharacterId(player),
		offer = {},
		confirmed = false,
	}
end

function TradeEngine:_stopTimer(trade)
	if trade._cancelTimer then
		trade._cancelTimer()
		trade._cancelTimer = nil
	end
	trade._token = nil
end

function TradeEngine:_describeOffer(side)
	local out = {}
	for _, entry in ipairs(side.offer) do
		local item = self._d.inventory:GetItem(entry.uid)
		table.insert(out, { uid = entry.uid, itemId = item and item.itemId or side._itemIds[entry.uid], quantity = entry.quantity })
	end
	return out
end

function TradeEngine:_close(trade, status, reason, cancelledBy)
	if isClosed(trade) then
		return
	end
	self:_stopTimer(trade)
	trade.state = status
	trade.reason = reason
	trade.closedAt = self._d.now()
	for _, side in ipairs({ trade.a, trade.b }) do
		if self._byPlayer[side.player] == trade then
			self._byPlayer[side.player] = nil
		end
	end
	self._trades[trade.id] = nil
	self._d.log:Record({
		kind = "Trade",
		tradeId = trade.id,
		status = status,
		reason = reason,
		cancelledBy = cancelledBy and self._d.getUserId(cancelledBy) or nil,
		pdEventId = trade.pdEventId,
		startedAt = trade.createdAt,
		players = { trade.a.userId, trade.b.userId },
		parties = {
			{ userId = trade.a.userId, characterId = trade.a.characterId, offered = self:_describeOffer(trade.a) },
			{ userId = trade.b.userId, characterId = trade.b.characterId, offered = self:_describeOffer(trade.b) },
		},
	})
	self._onUpdate(trade, status)
end

--------------------------------------------------------------------------------
-- Public API. Every method returns ok, and either the trade or a reason string.
--------------------------------------------------------------------------------

function TradeEngine:Request(from, to)
	if from == to then
		return false, "CannotTradeSelf"
	end
	if self._byPlayer[from] then
		return false, "AlreadyTrading"
	end
	if self._byPlayer[to] then
		return false, "OtherAlreadyTrading"
	end
	local ok, reason = self:_checkPair(from, to)
	if not ok then
		return false, reason
	end

	local trade = {
		id = self._newId(),
		state = State.Pending,
		a = self:_newSide(from),
		b = self:_newSide(to),
		createdAt = self._d.now(),
		pdEventId = self._d.getPDEventId and self._d.getPDEventId() or nil,
	}
	trade.a._itemIds = {}
	trade.b._itemIds = {}
	self._trades[trade.id] = trade
	self._byPlayer[from] = trade
	self._byPlayer[to] = trade

	trade._cancelTimer = self._d.delay(self._cfg.TradeRequestTimeoutSeconds, function()
		if trade.state == State.Pending then
			self:_close(trade, State.Expired, "RequestTimedOut")
		end
	end)
	self._onUpdate(trade, "Requested")
	return true, trade
end

function TradeEngine:Respond(player, tradeId, accept)
	local trade = self._trades[tradeId]
	if not trade or trade.state ~= State.Pending then
		return false, "NoSuchRequest"
	end
	if trade.b.player ~= player then
		return false, "NotRecipient"
	end
	if not accept then
		self:_close(trade, State.Declined, "Declined", player)
		return true, trade
	end
	local ok, reason = self:_checkPair(trade.a.player, trade.b.player)
	if not ok then
		self:_close(trade, State.Cancelled, reason)
		return false, reason
	end
	self:_stopTimer(trade)
	trade.state = State.Open
	self._onUpdate(trade, "Opened")
	return true, trade
end

-- items: array of { uid = string, quantity = number }; replaces the player's whole offer.
function TradeEngine:SetOffer(player, tradeId, items)
	local trade = self._trades[tradeId]
	if not trade or (trade.state ~= State.Open and trade.state ~= State.Countdown) then
		return false, "TradeNotOpen"
	end
	local side = self:_side(trade, player)
	if not side then
		return false, "NotParticipant"
	end
	if type(items) ~= "table" then
		return false, "InvalidOffer"
	end
	local offer = copyOffer(items)
	local ok, reason = self:_checkOffer(side, offer)
	if not ok then
		return false, reason
	end
	side.offer = offer
	for _, entry in ipairs(offer) do
		side._itemIds[entry.uid] = self._d.inventory:GetItem(entry.uid).itemId
	end
	-- Any change voids both confirmations and stops a running countdown.
	self:_stopTimer(trade)
	trade.a.confirmed = false
	trade.b.confirmed = false
	trade.state = State.Open
	self._onUpdate(trade, "OfferChanged")
	return true, trade
end

function TradeEngine:Confirm(player, tradeId)
	local trade = self._trades[tradeId]
	if not trade or trade.state ~= State.Open then
		return false, "TradeNotOpen"
	end
	local side = self:_side(trade, player)
	if not side then
		return false, "NotParticipant"
	end
	if #trade.a.offer == 0 and #trade.b.offer == 0 then
		return false, "NothingToTrade"
	end
	local ok, reason = self:_checkTrade(trade)
	if not ok then
		self:_close(trade, State.Cancelled, reason)
		return false, reason
	end
	side.confirmed = true
	if trade.a.confirmed and trade.b.confirmed then
		trade.state = State.Countdown
		local token = {}
		trade._token = token
		trade.countdownEndsAt = self._d.now() + self._cfg.TradeCountdownSeconds
		trade._cancelTimer = self._d.delay(self._cfg.TradeCountdownSeconds, function()
			self:_finalize(trade, token)
		end)
		self._onUpdate(trade, "CountdownStarted")
	else
		self._onUpdate(trade, "Confirmed")
	end
	return true, trade
end

function TradeEngine:Cancel(player, tradeId, reason)
	local trade = self._trades[tradeId]
	if not trade or isClosed(trade) then
		return false, "NoSuchTrade"
	end
	if not self:_side(trade, player) then
		return false, "NotParticipant"
	end
	self:_close(trade, State.Cancelled, reason or "PlayerCancelled", player)
	return true, trade
end

-- Cancels whatever trade the player is in (leaving, dying, entering combat...).
function TradeEngine:CancelForPlayer(player, reason)
	local trade = self._byPlayer[player]
	if trade then
		self:_close(trade, State.Cancelled, reason, player)
		return true
	end
	return false
end

-- Cancels every open trade, e.g. when the PD pauses or ends.
function TradeEngine:CancelAll(reason)
	local list = {}
	for _, trade in pairs(self._trades) do
		table.insert(list, trade)
	end
	for _, trade in ipairs(list) do
		self:_close(trade, State.Cancelled, reason)
	end
	return #list
end

function TradeEngine:_finalize(trade, token)
	-- A stale countdown (offer changed, cancelled, already finished) does nothing.
	if trade.state ~= State.Countdown or trade._token ~= token then
		return false, "Stale"
	end
	trade._token = nil
	trade._cancelTimer = nil

	local ok, reason = self:_checkTrade(trade)
	if not ok then
		self:_close(trade, State.Cancelled, "ValidationFailed:" .. reason)
		return false, reason
	end

	local Container = self._d.inventory.Container
	local aInv = Container.Character(trade.a.characterId)
	local bInv = Container.Character(trade.b.characterId)
	local transfers = {}
	for _, entry in ipairs(trade.a.offer) do
		table.insert(transfers, { uid = entry.uid, quantity = entry.quantity, from = aInv, to = bInv })
	end
	for _, entry in ipairs(trade.b.offer) do
		table.insert(transfers, { uid = entry.uid, quantity = entry.quantity, from = bInv, to = aInv })
	end

	-- Record item ids before the move (stackable uids may merge into the receiver's stacks).
	for _, side in ipairs({ trade.a, trade.b }) do
		for _, entry in ipairs(side.offer) do
			side._itemIds[entry.uid] = self._d.inventory:GetItem(entry.uid).itemId
		end
	end

	local applied, applyReason = self._d.inventory:ApplyTransfers(transfers)
	if not applied then
		self:_close(trade, State.Cancelled, "ValidationFailed:" .. tostring(applyReason))
		return false, applyReason
	end
	self:_close(trade, State.Completed, nil)
	return true
end

-- Read-only view of a trade for sending to clients.
function TradeEngine:Describe(trade)
	local function side(s)
		return { userId = s.userId, confirmed = s.confirmed, offer = self:_describeOffer(s) }
	end
	return {
		id = trade.id,
		state = trade.state,
		reason = trade.reason,
		countdownEndsAt = trade.countdownEndsAt,
		a = side(trade.a),
		b = side(trade.b),
	}
end

return TradeEngine
