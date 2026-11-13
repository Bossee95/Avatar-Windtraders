--[[
	GatheringService (GDD §10)

	Turns world parts tagged "ResourceNode" into finite resource nodes. Gathering is a
	server-timed channel; the yield goes straight into the character's carried
	inventory through InventoryService.

	Public API:
		GatheringService:GetEngine()
		GatheringService:SetTerritoryRule(fn(player, territoryKey, nodeId) -> boolean?)
		GatheringService:AdminSetEnabled(actor, nodeId, enabled)    -> ok, err
		GatheringService:AdminSetCapacity(actor, nodeId, capacity)  -> ok, err
		GatheringService:AdminSetRemaining(actor, nodeId, remaining)-> ok, err
		GatheringService:AdminRefillAll(actor)                      -> ok, count
		GatheringService.Gathered:Connect(fn(player, characterId, nodeId, items))

	Staff methods require the ManageResources permission.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ProductionConfig = require(ReplicatedStorage.Shared.Production.ProductionConfig)
local ResourceNodes = require(ReplicatedStorage.Shared.Production.Config.ResourceNodes)

local Channels = require(script.Parent.Channels)
local Deps = require(script.Parent.ProductionDeps)
local NodeEngine = require(script.Parent.NodeEngine)
local WorldStore = require(script.Parent.WorldStore)

local NODE_TAG = "ResourceNode"
local STORE_KEY = "nodes"
local MANAGE = "ManageResources"

local GatheringService = {}
GatheringService.Gathered = Signal.new()

local engine
local instances = {} -- nodeId -> Instance
local territoryRule = nil
local dirty = false

local function nodeIdOf(instance)
	return instance:GetAttribute("NodeId") or instance:GetFullName()
end

local function broadcast(nodeId)
	local snap = engine:Snapshot(nodeId)
	if snap then
		Net.FireAll("NodeState", snap)
	end
	dirty = true
end

local function addInstance(instance)
	local nodeType = instance:GetAttribute("NodeType")
	local nodeId = nodeIdOf(instance)
	local ok, err = engine:AddNode(nodeId, nodeType, { territory = instance:GetAttribute("Territory") })
	if not ok then
		warn(("[Production] Node %s (%s) ignored: %s"):format(nodeId, tostring(nodeType), err))
		return
	end
	instances[nodeId] = instance
end

local function removeInstance(instance)
	local nodeId = nodeIdOf(instance)
	if instances[nodeId] == instance then
		instances[nodeId] = nil
		engine:RemoveNode(nodeId)
	end
end

local function territoryOk(player, nodeId)
	local node = engine:Get(nodeId)
	if not territoryRule or not node or not node.territory then
		return nil
	end
	return territoryRule(player, node.territory, nodeId)
end

local function check(player, nodeId)
	if not Deps.pdAllows(ProductionConfig.GatherRequiresActivePD) then
		return false, "NoActivePD"
	end
	local character = Deps.character(player)
	if not character then
		return false, "NoLivingCharacter"
	end
	local instance = instances[nodeId]
	if not instance then
		return false, "UnknownNode"
	end
	if Deps.distanceTo(player, Deps.positionOf(instance)) > ProductionConfig.GatherRange then
		return false, "OutOfRange"
	end
	local inventory = Deps.inventory()
	if not inventory then
		return false, "InventoryUnavailable"
	end
	return engine:CanGather(nodeId, {
		faction = character.faction,
		hasItem = function(itemId)
			return inventory:HasItem(player, itemId, 1)
		end,
		territoryOk = territoryOk(player, nodeId),
	})
end

local function complete(player, nodeId, characterId)
	local inventory = Deps.inventory()
	local character = Deps.character(player)
	if not inventory or not character or character.id ~= characterId then
		return false, "NoLivingCharacter"
	end
	local items = engine:Harvest(nodeId)
	local granted = {}
	for itemId, qty in pairs(items) do
		local ok, err = inventory:Grant(player, itemId, qty)
		if not ok then
			-- Undo partial grants so a failed gather costs nothing.
			for gid, gqty in pairs(granted) do
				inventory:Consume(player, gid, gqty)
			end
			engine:Refund(nodeId)
			return false, err
		end
		granted[itemId] = qty
	end
	broadcast(nodeId)
	Deps.audit(player, "Production.Gather", { characterId = characterId, nodeId = nodeId, items = items })
	GatheringService.Gathered:Fire(player, characterId, nodeId, items)
	return true, nil, items
end

function GatheringService:StartGather(player, nodeId)
	if type(nodeId) ~= "string" then
		return false, "BadRequest"
	end
	local ok, err = check(player, nodeId)
	if not ok then
		return false, err
	end
	local character = Deps.character(player)
	local _, def = engine:Get(nodeId)
	local started, busy = Channels.Start(player, {
		kind = "Gather",
		id = nodeId,
		duration = def.gatherTime,
		stillValid = function()
			return check(player, nodeId)
		end,
		onComplete = function()
			return complete(player, nodeId, character.id)
		end,
	})
	if not started then
		return false, busy
	end
	return true, def.gatherTime
end

function GatheringService:GetEngine()
	return engine
end

function GatheringService:SetTerritoryRule(fn)
	territoryRule = fn
end

local function admin(actor, action, details, fn)
	if not Deps.hasStaffPermission(actor, MANAGE) then
		return false, "NotPermitted"
	end
	local ok, err = fn()
	if ok then
		Deps.audit(actor, action, details)
	end
	return ok, err
end

function GatheringService:AdminSetEnabled(actor, nodeId, enabled)
	return admin(actor, "Production.NodeEnabled", { nodeId = nodeId, enabled = enabled }, function()
		local ok, err = engine:SetEnabled(nodeId, enabled)
		if ok then
			broadcast(nodeId)
		end
		return ok, err
	end)
end

function GatheringService:AdminSetCapacity(actor, nodeId, capacity)
	return admin(actor, "Production.NodeCapacity", { nodeId = nodeId, capacity = capacity }, function()
		local ok, err = engine:SetCapacity(nodeId, capacity)
		if ok then
			broadcast(nodeId)
		end
		return ok, err
	end)
end

function GatheringService:AdminSetRemaining(actor, nodeId, remaining)
	return admin(actor, "Production.NodeRemaining", { nodeId = nodeId, remaining = remaining }, function()
		local ok, err = engine:SetRemaining(nodeId, remaining)
		if ok then
			broadcast(nodeId)
		end
		return ok, err
	end)
end

function GatheringService:AdminRefillAll(actor)
	local count = 0
	local ok, err = admin(actor, "Production.NodeRefillAll", {}, function()
		for _, snap in ipairs(engine:List()) do
			engine:SetRemaining(snap.nodeId, snap.capacity)
			broadcast(snap.nodeId)
			count = count + 1
		end
		return true
	end)
	return ok, ok and count or err
end

function GatheringService:Init()
	engine = NodeEngine.new({ nodeTypes = ResourceNodes })
end

function GatheringService:Start()
	engine:Load(WorldStore.Load(STORE_KEY))

	for _, instance in ipairs(CollectionService:GetTagged(NODE_TAG)) do
		addInstance(instance)
	end
	CollectionService:GetInstanceAddedSignal(NODE_TAG):Connect(addInstance)
	CollectionService:GetInstanceRemovedSignal(NODE_TAG):Connect(removeInstance)

	Net.OnInvoke("GatherStart", function(player, nodeId)
		return GatheringService:StartGather(player, nodeId)
	end, { rateLimit = 4 })
	Net.OnInvoke("ChannelCancel", function(player)
		Channels.Cancel(player, "Cancelled")
		return true
	end, { rateLimit = 4 })

	local PDEventService = Deps.service("PDEventService")
	if PDEventService then
		PDEventService.EventStarted:Connect(function()
			for _, nodeId in ipairs(engine:RefillForEvent()) do
				broadcast(nodeId)
			end
		end)
		PDEventService.EventEnded:Connect(function()
			WorldStore.Save(STORE_KEY, engine:Serialize())
			dirty = false
		end)
	end

	RunService.Heartbeat:Connect(function(dt)
		if Deps.pdAllows(true) then
			for _, nodeId in ipairs(engine:Tick(dt)) do
				broadcast(nodeId)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(ProductionConfig.WorldSaveInterval)
			if dirty then
				dirty = false
				WorldStore.Save(STORE_KEY, engine:Serialize())
			end
		end
	end)
	game:BindToClose(function()
		WorldStore.Save(STORE_KEY, engine:Serialize())
	end)
end

return GatheringService
