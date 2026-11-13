--[[
	DeathSatchelService

	Connects SatchelEngine (GDD §9.2, §16.3 step 4) to the game.

	- Registers the "Satchel" Permadeath transfer hook. It runs after the character is
	  marked dead and before its sections are wiped, moves the tradeable items it
	  carried into a satchel, and places the satchel in the world at the death location.
	  If the death is rolled back, the rollback hook removes the satchel again.
	- A satchel can be looted only during the PD it was created in (and not while that
	  PD is paused, unless EconomyConfig.SatchelLootWhilePaused).
	- When the PD ends, every satchel from it and its unclaimed contents are removed.

	Satchels are deliberately not saved: they only exist for the PD they belong to.
	If the server shuts down mid-PD its satchels are lost with it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Net = require(ReplicatedStorage.Shared.Net)
local EconomyConfig = require(ReplicatedStorage.Shared.Economy.EconomyConfig)
local SatchelEngine = require(script.Parent.SatchelEngine)
local EconomyDeps = require(script.Parent.EconomyDeps)
local InventoryService = require(script.Parent.InventoryService)
local TradeLogService = require(script.Parent.TradeLogService)
local TradeService = require(script.Parent.TradeService)

local DeathSatchelService = {}

local parts = {} -- satchelId -> BasePart
local folder

local function getFolder()
	if not folder or not folder.Parent then
		folder = Instance.new("Folder")
		folder.Name = "DeathSatchels"
		folder.Parent = workspace
	end
	return folder
end

local function isLootOpen(eventId)
	local PDEventService = EconomyDeps.service("PDEventService")
	local event = PDEventService and PDEventService:GetActiveEvent()
	if not event or event.id ~= eventId then
		return false
	end
	return not event.paused or EconomyConfig.SatchelLootWhilePaused == true
end

local engine

local function openFor(player, satchelId)
	local ok, contentsOrReason = engine:Open(player, satchelId)
	if ok then
		Net.Fire("SatchelOpened", player, satchelId, contentsOrReason)
	end
end

local function spawnPart(satchel)
	if typeof(satchel.location) ~= "CFrame" then
		return
	end
	-- Placeholder visual; swap for a proper model when art is ready.
	local part = Instance.new("Part")
	part.Name = "Satchel_" .. satchel.id
	part.Size = Vector3.new(1.5, 1, 1.5)
	part.Anchored = true
	part.CanCollide = false
	part.CFrame = satchel.location
	part:SetAttribute("SatchelId", satchel.id)
	part:SetAttribute("PDEventId", satchel.pdEventId)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Search"
	prompt.ObjectText = "Satchel"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = EconomyConfig.SatchelLootRange or 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		openFor(player, satchel.id)
	end)

	part.Parent = getFolder()
	parts[satchel.id] = part
end

local function removePart(satchel)
	local part = parts[satchel.id]
	parts[satchel.id] = nil
	if part then
		part:Destroy()
	end
end

engine = SatchelEngine.new({
	inventory = InventoryService:GetStore(),
	registry = InventoryService:GetRegistry(),
	log = TradeLogService:GetLog(),
	config = EconomyConfig,
	now = os.time,
	newId = function()
		return HttpService:GenerateGUID(false)
	end,
	isLootOpen = isLootOpen,
	getUserId = function(player)
		return player.UserId
	end,
	getCharacterId = EconomyDeps.livingCharacterId,
	getFaction = EconomyDeps.faction,
	getDistance = EconomyDeps.distanceTo,
	-- Instances are created in a new thread so the Permadeath hook never yields.
	onCreated = function(satchel)
		task.defer(spawnPart, satchel)
	end,
	onRemoved = function(satchel)
		task.defer(removePart, satchel)
	end,
})

local pending = {} -- characterId -> CreateFromDeath result, until the death commits

local function deathFromCtx(ctx)
	return {
		userId = ctx.userId,
		characterId = ctx.characterId,
		pdEventId = ctx.pdEventId,
		faction = ctx.character and ctx.character.faction or nil,
		location = ctx.location,
	}
end

function DeathSatchelService:Init()
	local PermadeathService = EconomyDeps.service("PermadeathService")
	PermadeathService:RegisterTransferHook("Satchel", function(ctx)
		-- An open trade must not complete with items that are about to move.
		if ctx.player then
			TradeService:CancelForPlayer(ctx.player, "Died")
			engine:ReleasePlayer(ctx.player)
		end
		InventoryService:EnsureLoaded(ctx.characterId, ctx.sections and ctx.sections.Inventory)
		pending[ctx.characterId] = engine:CreateFromDeath(deathFromCtx(ctx))
	end, {
		rollback = function(ctx)
			local result = pending[ctx.characterId]
			pending[ctx.characterId] = nil
			if result then
				engine:UndoDeath(deathFromCtx(ctx), result)
			end
		end,
	})
end

function DeathSatchelService:Start()
	local PermadeathService = EconomyDeps.service("PermadeathService")
	PermadeathService.Permadeath:Connect(function(_player, _userId, characterId)
		pending[characterId] = nil
		-- The character is gone; drop its (now empty) container from memory.
		InventoryService:ReleaseCharacter(characterId)
	end)

	local PDEventService = EconomyDeps.service("PDEventService")
	if PDEventService then
		PDEventService.EventEnded:Connect(function(event)
			engine:ClearEvent(event.id, "PDEnded")
			-- Safety net: nothing outlives the PD it belongs to.
			engine:ClearStale(nil)
		end)
		PDEventService.EventStarted:Connect(function(event)
			engine:ClearStale(event.id)
		end)
	end

	Net.OnInvoke("SatchelLoot", function(player, satchelId, picks)
		return engine:Loot(player, satchelId, picks)
	end, {
		rateLimit = 4,
		validate = function(satchelId, picks)
			if type(satchelId) ~= "string" or #satchelId > 64 then
				return false
			end
			if picks == nil then
				return true
			end
			if type(picks) ~= "table" or #picks > 64 then
				return false
			end
			for _, pick in ipairs(picks) do
				if type(pick) ~= "table" or type(pick.uid) ~= "string" then
					return false
				end
				if pick.quantity ~= nil and type(pick.quantity) ~= "number" then
					return false
				end
			end
			return true
		end,
	})

	Net.OnEvent("SatchelClose", function(player, satchelId)
		engine:Close(player, satchelId)
	end, { validate = function(satchelId)
		return type(satchelId) == "string"
	end })

	Players.PlayerRemoving:Connect(function(player)
		engine:ReleasePlayer(player)
	end)
end

--------------------------------------------------------------------------------
-- Public API (staff tools)
--------------------------------------------------------------------------------

function DeathSatchelService:GetEngine()
	return engine
end

function DeathSatchelService:List(pdEventId)
	return engine:List(pdEventId)
end

function DeathSatchelService:Contents(satchelId)
	return engine:Contents(satchelId)
end

-- Moderator tool: removes every satchel of an event now.
function DeathSatchelService:ClearEvent(pdEventId)
	return engine:ClearEvent(pdEventId, "StaffCleared")
end

return DeathSatchelService
