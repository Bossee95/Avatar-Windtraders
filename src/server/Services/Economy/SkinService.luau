--[[
	SkinService

	Account-wide weapon skin storage (GDD §7.3, §16.6). Skins live in the account-scope
	"Skins" data section, which Permanent Death never touches.

	The Dev Team tool in the staff thread does the permission check (AssignSkins) and
	writes the audit entry. This service only stores and validates. All calls work for
	offline accounts too (via DataService:UpdateOffline).

	There is no trade or transfer function, on purpose.

	Equipping: the player picks one owned skin per weapon type (inventory, Customise
	page). Choices are kept in the same section as `equipped = { [weaponType] = skinId }`.
	A skin's look is ServerStorage.WeaponSkins.<skinId> (a BasePart, or a Model with a
	PrimaryPart, set up like ServerStorage.WeaponModels). Give it a "WeaponType"
	attribute (e.g. "Spear") to limit it to one weapon type and an optional
	"DisplayName" attribute. CombatService welds it in place of the normal model.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local SkinStore = require(script.Parent.SkinStore)
local EconomyDeps = require(script.Parent.EconomyDeps)

local SkinService = {}

local SECTION = "Skins"

local function withOwned(userId, fn)
	local DataService = EconomyDeps.service("DataService")
	local player = Players:GetPlayerByUserId(userId)
	if player then
		local section = DataService:GetAccountSection(player, SECTION)
		if not section then
			return false, "AccountNotLoaded"
		end
		return fn(section.owned)
	end
	local result, reason
	local ok, err = DataService:UpdateOffline(userId, function(account)
		local section = account.sections[SECTION]
		if not section then
			section = { owned = {} }
			account.sections[SECTION] = section
		end
		section.owned = section.owned or {}
		result, reason = fn(section.owned)
	end)
	if not ok then
		return false, err
	end
	return result, reason
end

function SkinService:Init()
	EconomyDeps.service("DataService")
		:RegisterSection(SECTION, { scope = "Account", default = { owned = {}, equipped = {} } })
end

function SkinService:Start()
	local CombatService = EconomyDeps.service("CombatService")
	if CombatService and CombatService.SetWeaponSkinProvider then
		CombatService:SetWeaponSkinProvider(function(player, _variationId, weaponType)
			local skinId = SkinService:GetEquippedSkin(player, weaponType)
			return skinId and SkinService:GetSkinModel(skinId)
		end)
	end
end

-- The model for a skin, or nil if the place has none yet.
function SkinService:GetSkinModel(skinId)
	local folder = ServerStorage:FindFirstChild("WeaponSkins")
	return folder and folder:FindFirstChild(skinId) or nil
end

-- The weapon type a skin is for, or nil if it fits any weapon.
function SkinService:GetSkinWeaponType(skinId)
	local model = self:GetSkinModel(skinId)
	local weaponType = model and model:GetAttribute("WeaponType")
	return type(weaponType) == "string" and weaponType or nil
end

function SkinService:GetSkinDisplayName(skinId)
	local model = self:GetSkinModel(skinId)
	local name = model and model:GetAttribute("DisplayName")
	return type(name) == "string" and name or skinId
end

function SkinService:GetEquippedSkin(player, weaponType)
	local DataService = EconomyDeps.service("DataService")
	local section = DataService and DataService:GetAccountSection(player, SECTION)
	local skinId = section and section.equipped and section.equipped[weaponType]
	if skinId and SkinStore.Owns(section.owned, skinId) then
		return skinId
	end
	return nil
end

-- Wears an owned skin on a weapon type, or clears it with skinId = nil.
-- Returns ok, err.
function SkinService:EquipSkin(player, weaponType, skinId)
	local DataService = EconomyDeps.service("DataService")
	local section = DataService and DataService:GetAccountSection(player, SECTION)
	if not section then
		return false, "AccountNotLoaded"
	end
	if type(weaponType) ~= "string" or #weaponType > 50 then
		return false, "InvalidWeaponType"
	end
	section.equipped = section.equipped or {}
	if skinId == nil then
		section.equipped[weaponType] = nil
		return true
	end
	if not SkinStore.Owns(section.owned, skinId) then
		return false, "NotOwned"
	end
	if not self:GetSkinModel(skinId) then
		return false, "NoModel"
	end
	local skinType = self:GetSkinWeaponType(skinId)
	if skinType and skinType ~= weaponType then
		return false, "WrongWeaponType"
	end
	section.equipped[weaponType] = skinId
	return true
end

-- Returns ok, err.
function SkinService:GrantSkin(actorUserId, userId, skinId, note)
	return withOwned(userId, function(owned)
		return SkinStore.Grant(owned, skinId, actorUserId, os.time(), note)
	end)
end

function SkinService:RevokeSkin(_actorUserId, userId, skinId)
	return withOwned(userId, function(owned)
		return SkinStore.Revoke(owned, skinId)
	end)
end

-- Returns { skinId } (sorted), or an empty list if the account cannot be read.
function SkinService:GetSkins(userId)
	local list = {}
	withOwned(userId, function(owned)
		list = SkinStore.List(owned)
		return true
	end)
	return list
end

-- Fast check for online players (e.g. when equipping a cosmetic).
function SkinService:Owns(player, skinId)
	local DataService = EconomyDeps.service("DataService")
	local section = DataService and DataService:GetAccountSection(player, SECTION)
	return section ~= nil and SkinStore.Owns(section.owned, skinId)
end

return SkinService
