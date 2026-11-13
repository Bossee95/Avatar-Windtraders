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

	The same actions are staff chat commands (registered with StaffCommandService):
		/nodes                         list nodes and their stock
		/node <nodeId> on|off
		/node <nodeId> capacity <n>
		/node <nodeId> stock <n>
		/nodes refill
		/recipe <recipeId> lock|unlock [faction]
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

local function reply(ok, result)
	if ok then
		return "Done" .. (type(result) == "number" and (" (" .. result .. ")") or "")
	end
	return "Failed: " .. tostring(result)
end

local function registerCommands()
	local StaffCommandService = Deps.service("StaffCommandService")
	if not StaffCommandService or not StaffCommandService.RegisterCommand then
		return
	end
	StaffCommandService:RegisterCommand("nodes", {
		usage = { "/nodes", "/nodes refill" },
		permissions = { "ManageResources" },
		run = function(player, args)
			if args[1] == "refill" then
				return reply(actions.RefillAllNodes(player))
			end
			local ok, list = actions.ListNodes(player)
			if not ok then
				return reply(ok, list)
			end
			local lines = {}
			for _, n in ipairs(list) do
				table.insert(lines, ("%s [%s] %d/%d%s"):format(n.nodeId, n.nodeType, n.remaining, n.capacity, n.enabled and "" or " (off)"))
			end
			return #lines > 0 and table.concat(lines, "\n") or "No nodes."
		end,
	})
	StaffCommandService:RegisterCommand("node", {
		usage = { "/node <nodeId> on|off", "/node <nodeId> capacity <n>", "/node <nodeId> stock <n>" },
		permissions = { "ManageResources" },
		run = function(player, args)
			local nodeId, verb, n = args[1], args[2], tonumber(args[3])
			if verb == "on" or verb == "off" then
				return reply(actions.SetNodeEnabled(player, nodeId, verb == "on"))
			elseif verb == "capacity" then
				return reply(actions.SetNodeCapacity(player, nodeId, n))
			elseif verb == "stock" then
				return reply(actions.SetNodeRemaining(player, nodeId, n))
			end
			return "Usage: /node <nodeId> on|off|capacity <n>|stock <n>"
		end,
	})
	StaffCommandService:RegisterCommand("recipe", {
		usage = { "/recipe <recipeId> lock|unlock [faction]" },
		permissions = { "ManageRecipes" },
		run = function(player, args)
			local recipeId, verb, faction = args[1], args[2], args[3]
			if verb ~= "lock" and verb ~= "unlock" then
				return "Usage: /recipe <recipeId> lock|unlock [faction]"
			end
			return reply(actions.SetRecipeLocked(player, recipeId, faction, verb == "lock"))
		end,
	})
end

-- StaffCommandService only accepts commands during Init.
function ProductionAdminService:Init()
	registerCommands()
end

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
