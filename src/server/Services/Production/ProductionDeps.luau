--[[
	ProductionDeps

	Lookups the production services need from other systems. Services are resolved
	lazily so gathering and crafting still boot while those branches are unmerged.
	Each gate that depends on a missing service fails closed (refuses) unless noted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local ProductionConfig = require(ReplicatedStorage.Shared.Production.ProductionConfig)

local Deps = {}

local warned = {}

function Deps.service(name)
	local ok, service = pcall(Loader.Get, name)
	if ok and service then
		return service
	end
	if not warned[name] then
		warned[name] = true
		warn(("[Production] %s is not available yet."):format(name))
	end
	return nil
end

-- The player's active living character, or nil.
function Deps.character(player)
	local CharacterService = Deps.service("CharacterService")
	local character = CharacterService and CharacterService:GetActiveCharacter(player)
	if character and character.status == "Alive" then
		return character
	end
	return nil
end

-- True when gathering/crafting is allowed by the PD state (fails closed without PDEventService).
function Deps.pdAllows(required)
	if not required then
		return true
	end
	local PDEventService = Deps.service("PDEventService")
	if not PDEventService then
		return false
	end
	if PDEventService:IsActive() then
		return true
	end
	-- IsActive() is false while paused.
	return ProductionConfig.AllowWhilePaused and PDEventService:GetState() == "Paused"
end

function Deps.inCombat(player)
	local CombatService = Deps.service("CombatService")
	return CombatService ~= nil and CombatService:IsInCombat(player) == true
end

-- Staff permission check (fails closed without StaffService).
function Deps.hasStaffPermission(player, permission)
	local StaffService = Deps.service("StaffService")
	return StaffService ~= nil and StaffService:HasPermission(player, permission) == true
end

function Deps.audit(actor, action, details)
	local AuditLogService = Deps.service("AuditLogService")
	if AuditLogService then
		AuditLogService:Record(actor and actor.UserId or 0, action, nil, details)
	end
end

-- Faction permission flag from the character's role (ProductionConfig.RolePermissions).
function Deps.roleHas(character, flag)
	local faction = WorldConfig.Factions[character.faction]
	local role = faction and faction.roles[character.role]
	if role and role.leadership then
		return true
	end
	local byFaction = ProductionConfig.RolePermissions[character.faction]
	local set = byFaction and byFaction[character.role]
	return set ~= nil and set[flag] == true
end

function Deps.inventory()
	return Deps.service("InventoryService")
end

function Deps.distanceTo(player, position)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not position then
		return math.huge
	end
	return (root.Position - position).Magnitude
end

-- World position of a tagged instance (BasePart or Model).
function Deps.positionOf(instance)
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

return Deps
