--[[
	ProductionAdminService

	The "ProductionAdmin" remote, so a staff UI (or the staff command line) can
	manage nodes and recipe locks. Every action is permission-checked and audited by
	the service it calls; this file only dispatches.

		ProductionAdmin("ListNodes")                          -> true, { node snapshot }
		ProductionAdmin("SetNodeEnabled",   nodeId, enabled)
		ProductionAdmin("SetNodeCapacity",  nodeId, capacity)
		ProductionAdmin("SetNodeRemaining", nodeId, remaining)
		ProductionAdmin("RefillAllNodes")                     -> true, count
		ProductionAdmin("SetRecipeLocked",  recipeId, faction | nil, locked)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local CraftingService = require(script.Parent.CraftingService)
local Deps = require(script.Parent.ProductionDeps)
local GatheringService = require(script.Parent.GatheringService)

local ProductionAdminService = {}

local actions = {
	ListNodes = function(player)
		if not Deps.hasStaffPermission(player, "ManageResources") then
			return false, "NotPermitted"
		end
		return true, GatheringService:GetEngine():List()
	end,
	SetNodeEnabled = function(player, nodeId, enabled)
		return GatheringService:AdminSetEnabled(player, nodeId, enabled == true)
	end,
	SetNodeCapacity = function(player, nodeId, capacity)
		return GatheringService:AdminSetCapacity(player, nodeId, capacity)
	end,
	SetNodeRemaining = function(player, nodeId, remaining)
		return GatheringService:AdminSetRemaining(player, nodeId, remaining)
	end,
	RefillAllNodes = function(player)
		return GatheringService:AdminRefillAll(player)
	end,
	SetRecipeLocked = function(player, recipeId, faction, locked)
		if faction ~= nil and type(faction) ~= "string" then
			return false, "BadRequest"
		end
		return CraftingService:AdminSetRecipeLocked(player, recipeId, faction, locked == true)
	end,
}

function ProductionAdminService:Start()
	Net.OnInvoke("ProductionAdmin", function(player, action, ...)
		local fn = type(action) == "string" and actions[action]
		if not fn then
			return false, "UnknownAction"
		end
		return fn(player, ...)
	end, { rateLimit = 5 })
end

return ProductionAdminService
