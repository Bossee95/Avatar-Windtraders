--[[
	CosmeticService

	Backs the inventory's Customise page:
	  * Weapon skins: lists the skins the account owns and wears one per weapon type
	    (ownership and the equipped choice live in SkinService's account section).
	  * Accessories: any Accessory in ServerStorage.CosmeticModels can be worn. The
	    choice is saved in the account-scope "Cosmetics" section, so it survives
	    Permanent Death like skins do, and is put back on every spawn with
	    Humanoid:AddAccessory (the same way the old menu attached them).

	Public API:
	  CosmeticService:Describe(player) -> state (also pushed as CosmeticsState)
	  CosmeticService:SetAccessory(player, accessoryId, wear) -> ok, err
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local CosmeticConfig = require(ReplicatedStorage.Shared.Cosmetics.CosmeticConfig)

local CosmeticService = {}

local SECTION = "Cosmetics"
local TAG = "Cosmetic" -- attribute on worn clones, holds the accessory id

local function service(name)
	local ok, found = pcall(Loader.Get, name)
	return ok and found or nil
end

local function accessoryFolder()
	return ServerStorage:FindFirstChild("CosmeticModels")
end

local function accessoryTemplate(accessoryId)
	local folder = accessoryFolder()
	local template = folder and type(accessoryId) == "string" and folder:FindFirstChild(accessoryId)
	if template and template:IsA("Accessory") then
		return template
	end
	return nil
end

local function attr(instance, name)
	local value = instance:GetAttribute(name)
	return type(value) == "string" and value ~= "" and value or nil
end

local function section(player)
	local DataService = service("DataService")
	return DataService and DataService:GetAccountSection(player, SECTION)
end

local function wornList(player)
	local data = section(player)
	local list = {}
	for accessoryId in pairs(data and data.accessories or {}) do
		if accessoryTemplate(accessoryId) then
			table.insert(list, accessoryId)
		end
	end
	table.sort(list)
	return list
end

-- Puts the saved accessories on the player's avatar (and takes off any that
-- are no longer chosen).
local function applyAccessories(player)
	local avatar = player.Character
	local humanoid = avatar and avatar:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local wanted = {}
	for _, accessoryId in ipairs(wornList(player)) do
		wanted[accessoryId] = true
	end
	for _, child in ipairs(avatar:GetChildren()) do
		local id = child:IsA("Accessory") and child:GetAttribute(TAG)
		if id then
			if wanted[id] then
				wanted[id] = nil -- already worn
			else
				child:Destroy()
			end
		end
	end
	for accessoryId in pairs(wanted) do
		local clone = accessoryTemplate(accessoryId):Clone()
		clone:SetAttribute(TAG, accessoryId)
		humanoid:AddAccessory(clone)
	end
end

function CosmeticService:Describe(player)
	local state = {
		skins = {},
		equippedSkins = {},
		accessories = {},
		worn = {},
		maxAccessories = CosmeticConfig.MaxAccessories,
	}

	local SkinService = service("SkinService")
	if SkinService then
		for _, skinId in ipairs(SkinService:GetSkins(player.UserId)) do
			table.insert(state.skins, {
				id = skinId,
				name = SkinService:GetSkinDisplayName(skinId),
				weaponType = SkinService:GetSkinWeaponType(skinId),
				hasModel = SkinService:GetSkinModel(skinId) ~= nil,
			})
		end
		local DataService = service("DataService")
		local skinSection = DataService and DataService:GetAccountSection(player, "Skins")
		for weaponType in pairs(skinSection and skinSection.equipped or {}) do
			state.equippedSkins[weaponType] = SkinService:GetEquippedSkin(player, weaponType)
		end
	end

	local folder = accessoryFolder()
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Accessory") then
				table.insert(state.accessories, {
					id = child.Name,
					name = attr(child, "DisplayName") or child.Name,
					slot = attr(child, "Slot"),
				})
			end
		end
		table.sort(state.accessories, function(a, b)
			return a.name < b.name
		end)
	end
	for _, accessoryId in ipairs(wornList(player)) do
		state.worn[accessoryId] = true
	end
	return state
end

local function push(player)
	Net.Fire("CosmeticsState", player, CosmeticService:Describe(player))
end

function CosmeticService:SetAccessory(player, accessoryId, wear)
	local data = section(player)
	if not data then
		return false, "AccountNotLoaded"
	end
	local template = accessoryTemplate(accessoryId)
	if not template then
		return false, "UnknownAccessory"
	end
	data.accessories = data.accessories or {}
	if wear then
		-- One per slot: wearing a new hat takes the old one off.
		local slot = attr(template, "Slot")
		if slot then
			for otherId in pairs(data.accessories) do
				local other = accessoryTemplate(otherId)
				if otherId ~= accessoryId and other and attr(other, "Slot") == slot then
					data.accessories[otherId] = nil
				end
			end
		end
		if not data.accessories[accessoryId] and #wornList(player) >= CosmeticConfig.MaxAccessories then
			return false, "TooMany"
		end
		data.accessories[accessoryId] = true
	else
		data.accessories[accessoryId] = nil
	end
	applyAccessories(player)
	push(player)
	return true
end

function CosmeticService:Init()
	service("DataService"):RegisterSection(SECTION, { scope = "Account", default = { accessories = {} } })
end

function CosmeticService:Start()
	local DataService = service("DataService")

	Net.OnInvoke("GetCosmetics", function(player)
		return CosmeticService:Describe(player)
	end)

	Net.OnInvoke("SetAccessory", function(player, accessoryId, wear)
		return CosmeticService:SetAccessory(player, accessoryId, wear == true)
	end, { rateLimit = 4 })

	Net.OnInvoke("EquipSkin", function(player, weaponType, skinId)
		local SkinService = service("SkinService")
		if not SkinService then
			return false, "Unavailable"
		end
		if skinId ~= nil and type(skinId) ~= "string" then
			return false, "InvalidSkinId"
		end
		local ok, err = SkinService:EquipSkin(player, weaponType, skinId)
		if ok then
			local CombatService = service("CombatService")
			if CombatService and CombatService.RefreshWeaponModel then
				CombatService:RefreshWeaponModel(player)
			end
			push(player)
		end
		return ok, err
	end, { rateLimit = 4 })

	local function onPlayer(player)
		player.CharacterAdded:Connect(function(avatar)
			avatar:WaitForChild("Humanoid", 10)
			applyAccessories(player)
		end)
		if player.Character then
			task.spawn(applyAccessories, player)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end

	if DataService then
		DataService.AccountLoaded:Connect(function(player)
			applyAccessories(player)
			push(player)
		end)
	end
end

return CosmeticService
