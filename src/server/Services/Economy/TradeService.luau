--[[
	TradeService

	Connects TradeEngine (the trading rules, GDD §8.3-8.4, §16.4) to the game: remotes,
	PD state, combat tags, characters and saving.

	Trades are cancelled when:
		- the PD pauses (unless EconomyConfig.TradeAllowedWhilePaused) or ends
		- either player leaves, switches character or dies
		- either player is combat-tagged (EconomyConfig.BlockTradeInCombat)
	A trader cannot switch characters while a trade is open.

	After a trade completes both accounts are saved immediately to keep the window
	between the two saves as short as possible.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local EconomyConfig = require(ReplicatedStorage.Shared.Economy.EconomyConfig)
local TradeEngine = require(script.Parent.TradeEngine)
local EconomyDeps = require(script.Parent.EconomyDeps)
local InventoryService = require(script.Parent.InventoryService)
local TradeLogService = require(script.Parent.TradeLogService)

local TradeService = {}

local engine -- created below, after the helpers it uses

local function isTradingOpen(player)
	local PDEventService = EconomyDeps.service("PDEventService")
	if not PDEventService then
		return false
	end
	if PDEventService:IsPlayerInActiveEvent(player) then
		return true
	end
	if EconomyConfig.TradeAllowedWhilePaused then
		local event = PDEventService:GetActiveEvent()
		return event ~= nil and event.paused == true and player.Parent == Players
	end
	return false
end

local function pdEventId()
	local PDEventService = EconomyDeps.service("PDEventService")
	local event = PDEventService and PDEventService:GetActiveEvent()
	return event and event.id or nil
end

local function saveBoth(trade)
	local DataService = EconomyDeps.service("DataService")
	for _, side in ipairs({ trade.a, trade.b }) do
		task.spawn(function()
			if side.player.Parent == Players then
				DataService:SaveNow(side.player)
			end
		end)
	end
end

local function onUpdate(trade, eventName)
	local description = engine:Describe(trade)
	for _, side in ipairs({ trade.a, trade.b }) do
		if side.player.Parent == Players then
			Net.Fire("TradeState", side.player, description, eventName)
		end
	end
	if eventName == TradeEngine.State.Completed then
		saveBoth(trade)
	end
end

engine = TradeEngine.new({
	inventory = InventoryService:GetStore(),
	registry = InventoryService:GetRegistry(),
	log = TradeLogService:GetLog(),
	config = EconomyConfig,
	now = function()
		return workspace:GetServerTimeNow()
	end,
	delay = function(seconds, fn)
		local thread = task.delay(seconds, fn)
		return function()
			pcall(task.cancel, thread)
		end
	end,
	getUserId = function(player)
		return player.UserId
	end,
	getCharacterId = EconomyDeps.livingCharacterId,
	getFaction = EconomyDeps.faction,
	isTradingOpen = isTradingOpen,
	getPDEventId = pdEventId,
	isInCombat = EconomyDeps.inCombat,
	getDistance = EconomyDeps.distance,
	onUpdate = onUpdate,
})

local function isString(v)
	return type(v) == "string" and #v <= 64
end

local function validOffer(items)
	if type(items) ~= "table" or #items > (EconomyConfig.MaxItemsPerOffer or 16) then
		return false
	end
	for _, entry in ipairs(items) do
		if type(entry) ~= "table" or not isString(entry.uid) or type(entry.quantity) ~= "number" then
			return false
		end
	end
	return true
end

function TradeService:Start()
	Net.OnInvoke("TradeRequest", function(player, targetUserId)
		local target = Players:GetPlayerByUserId(targetUserId)
		if not target then
			return false, "PlayerNotFound"
		end
		local ok, result = engine:Request(player, target)
		return ok, not ok and result or result.id
	end, {
		rateLimit = 1,
		validate = function(targetUserId)
			return type(targetUserId) == "number"
		end,
	})

	Net.OnInvoke("TradeRespond", function(player, tradeId, accept)
		local ok, result = engine:Respond(player, tradeId, accept == true)
		return ok, not ok and result or nil
	end, { validate = function(tradeId)
		return isString(tradeId)
	end })

	Net.OnInvoke("TradeSetOffer", function(player, tradeId, items)
		local ok, result = engine:SetOffer(player, tradeId, items)
		return ok, not ok and result or nil
	end, { validate = function(tradeId, items)
		return isString(tradeId) and validOffer(items)
	end })

	Net.OnInvoke("TradeConfirm", function(player, tradeId)
		local ok, result = engine:Confirm(player, tradeId)
		return ok, not ok and result or nil
	end, { validate = function(tradeId)
		return isString(tradeId)
	end })

	Net.OnInvoke("TradeCancel", function(player, tradeId)
		local ok, result = engine:Cancel(player, tradeId, "PlayerCancelled")
		return ok, not ok and result or nil
	end, { validate = function(tradeId)
		return isString(tradeId)
	end })

	Players.PlayerRemoving:Connect(function(player)
		engine:CancelForPlayer(player, "PlayerLeft")
	end)

	local CharacterService = EconomyDeps.service("CharacterService")
	if CharacterService then
		CharacterService:RegisterSwitchGuard("Trading", function(player)
			if engine:GetTradeForPlayer(player) then
				return false, "Trading"
			end
			return true
		end)
		CharacterService.CharacterSelected:Connect(function(player)
			engine:CancelForPlayer(player, "CharacterChanged")
		end)
	end

	local PDEventService = EconomyDeps.service("PDEventService")
	if PDEventService then
		PDEventService.EventPaused:Connect(function()
			if not EconomyConfig.TradeAllowedWhilePaused then
				engine:CancelAll("PDPaused")
			end
		end)
		PDEventService.EventEnded:Connect(function()
			engine:CancelAll("PDEnded")
		end)
	end

	local CombatService = EconomyDeps.service("CombatService")
	if CombatService and CombatService.CombatTagChanged then
		CombatService.CombatTagChanged:Connect(function(player, isTagged)
			if isTagged and EconomyConfig.BlockTradeInCombat then
				engine:CancelForPlayer(player, "InCombat")
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function TradeService:GetEngine()
	return engine
end

function TradeService:GetTradeForPlayer(player)
	return engine:GetTradeForPlayer(player)
end

-- Cancels any trade the player is in. Safe to call from a Permadeath hook (no yield).
function TradeService:CancelForPlayer(player, reason)
	return engine:CancelForPlayer(player, reason)
end

-- Moderator tool: cancels every open trade.
function TradeService:CancelAll(reason)
	return engine:CancelAll(reason or "StaffCancelled")
end

return TradeService
