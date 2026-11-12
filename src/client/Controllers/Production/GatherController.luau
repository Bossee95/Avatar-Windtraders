--[[
	GatherController

	Minimal client side for gathering and crafting: adds a ProximityPrompt to every
	resource node and crafting station, sends the request, and shows the result. The
	server decides everything; this only sends intents. A proper crafting UI can use
	the CraftList remote.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Net = require(ReplicatedStorage.Shared.Net)
local ResourceNodes = require(ReplicatedStorage.Shared.Production.Config.ResourceNodes)
local Stations = require(ReplicatedStorage.Shared.Production.Config.Stations)

local GatherController = {}

local function notify(text)
	pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "Gathering", Text = text, Duration = 3 })
end

local function promptOn(instance, actionText, objectText, holdTime, onTriggered)
	local part = instance:IsA("BasePart") and instance or (instance:IsA("Model") and instance.PrimaryPart)
	if not part then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = holdTime or 0
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(onTriggered)
end

local function setupNode(instance)
	local def = ResourceNodes[instance:GetAttribute("NodeType")]
	if not def then
		return
	end
	local nodeId = instance:GetAttribute("NodeId") or instance:GetFullName()
	promptOn(instance, "Gather", def.tier, 0, function()
		local ok, result = Net.Invoke("GatherStart", nodeId)
		if not ok then
			notify("Can't gather: " .. tostring(result))
		end
	end)
end

local function setupStation(instance)
	local stationType = instance:GetAttribute("StationType")
	local def = Stations[stationType]
	if not def then
		return
	end
	local stationId = instance:GetAttribute("StationId") or instance:GetFullName()
	promptOn(instance, "Craft", def.displayName, 0, function()
		local list = Net.Invoke("CraftList", stationId) or {}
		for _, recipe in ipairs(list) do
			if recipe.ok then
				local ok, result = Net.Invoke("CraftStart", recipe.id, stationId)
				if not ok then
					notify("Can't craft: " .. tostring(result))
				end
				return
			end
		end
		notify("Nothing you can craft here right now.")
	end)
end

function GatherController:Start()
	for _, inst in ipairs(CollectionService:GetTagged("ResourceNode")) do
		setupNode(inst)
	end
	CollectionService:GetInstanceAddedSignal("ResourceNode"):Connect(setupNode)
	for _, inst in ipairs(CollectionService:GetTagged("CraftingStation")) do
		setupStation(inst)
	end
	CollectionService:GetInstanceAddedSignal("CraftingStation"):Connect(setupStation)

	Net.OnEvent("ChannelEnded", function(result)
		if result.ok then
			local parts = {}
			for itemId, qty in pairs(result.items or {}) do
				table.insert(parts, ("%dx %s"):format(qty, itemId))
			end
			notify(#parts > 0 and ("Got " .. table.concat(parts, ", ")) or "Done")
		else
			notify(("%s stopped: %s"):format(result.kind, tostring(result.reason)))
		end
	end)
end

return GatherController
