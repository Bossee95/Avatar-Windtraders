--[[
	Lookups shared by the economy services: other systems' services (resolved lazily so
	the economy still boots while those branches are unmerged) and world positions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)

local EconomyDeps = {}

local warned = {}

-- Returns the named service, or nil (with one warning) if it is not loaded.
function EconomyDeps.service(name)
	local ok, service = pcall(Loader.Get, name)
	if ok and service then
		return service
	end
	if not warned[name] then
		warned[name] = true
		warn(("[Economy] %s is not available; related checks are disabled until it is."):format(name))
	end
	return nil
end

function EconomyDeps.rootPosition(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

function EconomyDeps.distance(a, b)
	local pa, pb = EconomyDeps.rootPosition(a), EconomyDeps.rootPosition(b)
	if not pa or not pb then
		return nil
	end
	return (pa - pb).Magnitude
end

-- location may be a CFrame or a Vector3.
function EconomyDeps.distanceTo(player, location)
	local p = EconomyDeps.rootPosition(player)
	if not p or location == nil then
		return nil
	end
	local target = typeof(location) == "CFrame" and location.Position or location
	return (p - target).Magnitude
end

-- The living, active character id of a player, or nil.
function EconomyDeps.livingCharacterId(player)
	local CharacterService = EconomyDeps.service("CharacterService")
	if not CharacterService then
		return nil
	end
	local character = CharacterService:GetActiveCharacter(player)
	if character and character.status == "Alive" then
		return character.id
	end
	return nil
end

function EconomyDeps.faction(player)
	local CharacterService = EconomyDeps.service("CharacterService")
	local character = CharacterService and CharacterService:GetActiveCharacter(player)
	return character and character.faction or nil
end

function EconomyDeps.inCombat(player)
	local CombatService = EconomyDeps.service("CombatService")
	return CombatService ~= nil and CombatService:IsInCombat(player) == true
end

return EconomyDeps
