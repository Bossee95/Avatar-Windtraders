--[[
	InventoryService

	Owns every character's carried items (GDD §8.1, §16.2).

	Items live in the character-scope "Inventory" data section, so they are saved with
	the session-locked account record and wiped by Permanent Death after the satchel
	hook has taken the tradeable ones. InventoryStore mirrors the active character's
	section in memory; every change is written straight back into the section table.

	Other systems (gathering, crafting, staff tools) add and remove items through the
	public API below, never by editing the section directly.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local ItemRegistry = require(ReplicatedStorage.Shared.Economy.ItemRegistry)
local EconomyConfig = require(ReplicatedStorage.Shared.Economy.EconomyConfig)
local ItemDefinitions = require(ReplicatedStorage.Shared.Economy.ItemDefinitions)
local InventoryStore = require(script.Parent.InventoryStore)
local EconomyDeps = require(script.Parent.EconomyDeps)

local InventoryService = {}

local SECTION = "Inventory"

local registry = ItemRegistry.new(ItemDefinitions)
local store = InventoryStore.new({
	registry = registry,
	categoryLimits = { Weapon = EconomyConfig.MaxWeaponsPerCharacter },
	newId = function()
		return HttpService:GenerateGUID(false)
	end,
})
local loaded = {} -- characterId -> player
local activeKey = {} -- player -> container key

local function sectionFor(player, characterId)
	local DataService = EconomyDeps.service("DataService")
	return DataService and DataService:GetCharacterSection(player, SECTION, characterId)
end

local function pushToClient(player)
	local key = activeKey[player]
	if key then
		Net.Fire("InventoryUpdated", player, { items = store:Serialize(key) })
	end
end

local function onStoreChanged(changed)
	for key in pairs(changed) do
		local characterId = key:match("^char:(.+)$")
		local player = characterId and loaded[characterId]
		if player then
			local section = sectionFor(player, characterId)
			if section then
				section.items = store:Serialize(key)
			end
			pushToClient(player)
			-- An equipped weapon that is no longer carried must be unequipped.
			local CombatService = EconomyDeps.service("CombatService")
			if CombatService then
				task.defer(CombatService.Revalidate, CombatService, player)
			end
		end
	end
end

local function unloadPlayer(player)
	local key = activeKey[player]
	if key then
		local characterId = key:match("^char:(.+)$")
		loaded[characterId] = nil
		activeKey[player] = nil
		store:Unload(key)
	end
end

local function loadCharacter(player, characterId)
	unloadPlayer(player)
	if not characterId then
		return
	end
	local section = sectionFor(player, characterId)
	if not section then
		return
	end
	local key = InventoryStore.Container.Character(characterId)
	local skipped = store:Load(key, section.items)
	if #skipped > 0 then
		warn(("[Inventory] %d unknown item(s) skipped for character %s"):format(#skipped, characterId))
	end
	local weapons = store:CountCategory(key, "Weapon")
	if weapons > EconomyConfig.MaxWeaponsPerCharacter then
		-- Saved before the one-weapon rule. Nothing is deleted; the character just
		-- cannot gain another weapon until it is down to the limit.
		warn(
			("[Inventory] character %s carries %d weapons (limit %d)"):format(
				characterId,
				weapons,
				EconomyConfig.MaxWeaponsPerCharacter
			)
		)
	end
	loaded[characterId] = player
	activeKey[player] = key
	pushToClient(player)
end

function InventoryService:Init()
	store:OnChanged(onStoreChanged)

	local DataService = EconomyDeps.service("DataService")
	DataService:RegisterSection(SECTION, { scope = "Character", default = { items = {} } })
end

function InventoryService:Start()
	local CombatService = EconomyDeps.service("CombatService")
	if CombatService and CombatService.SetVariationOwnershipProvider then
		CombatService:SetVariationOwnershipProvider(function(player, variationId)
			return InventoryService:HasVariation(player, variationId)
		end)
	end

	local CharacterService = EconomyDeps.service("CharacterService")
	local DataService = EconomyDeps.service("DataService")

	-- The inventory screen asks once on start, in case the first push came
	-- before it was listening.
	Net.OnInvoke("GetInventory", function(player)
		return { items = InventoryService:GetItems(player) }
	end)

	CharacterService.CharacterSelected:Connect(function(player, characterId)
		loadCharacter(player, characterId)
	end)
	DataService.AccountReleasing:Connect(function(player)
		unloadPlayer(player)
	end)
	Players.PlayerRemoving:Connect(unloadPlayer)

	-- Players who selected a character before Start ran.
	for _, player in ipairs(Players:GetPlayers()) do
		local characterId = CharacterService:GetActiveCharacterId(player)
		if characterId and not activeKey[player] then
			loadCharacter(player, characterId)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function InventoryService:GetRegistry()
	return registry
end

-- The engine-level store, for TradeService and DeathSatchelService.
function InventoryService:GetStore()
	return store
end

-- Makes sure a character's items are in memory (e.g. for a death processed while the
-- character is not the selected one). Returns the container key.
function InventoryService:EnsureLoaded(characterId, sectionTable)
	local key = InventoryStore.Container.Character(characterId)
	if not loaded[characterId] and sectionTable then
		store:Load(key, sectionTable.items)
	end
	return key
end

function InventoryService:ReleaseCharacter(characterId)
	local player = loaded[characterId]
	if player then
		unloadPlayer(player)
	else
		store:Unload(InventoryStore.Container.Character(characterId))
	end
end

function InventoryService:GetPlayerForCharacter(characterId)
	return loaded[characterId]
end

-- Snapshot of the player's carried items: { {uid, itemId, quantity} }.
function InventoryService:GetItems(player)
	local key = activeKey[player]
	return key and store:Serialize(key) or {}
end

function InventoryService:Count(player, itemId)
	local key = activeKey[player]
	return key and store:CountOf(key, itemId) or 0
end

function InventoryService:HasItem(player, itemId, quantity)
	return self:Count(player, itemId) >= (quantity or 1)
end

function InventoryService:HasVariation(player, variationId)
	local key = activeKey[player]
	if not key then
		return false
	end
	for _, item in ipairs(store:GetContainer(key)) do
		local def = registry:Get(item.itemId)
		if def and def.variationId == variationId then
			return true
		end
	end
	return false
end

-- Gives the player's living character items. Returns ok, err.
function InventoryService:Grant(player, itemId, quantity)
	local key = activeKey[player]
	if not key or not EconomyDeps.livingCharacterId(player) then
		return false, "NoLivingCharacter"
	end
	if not registry:Exists(itemId) then
		return false, "UnknownItem"
	end
	quantity = quantity or 1
	if type(quantity) ~= "number" or quantity < 1 or quantity ~= math.floor(quantity) then
		return false, "InvalidQuantity"
	end
	local granted, reason = store:Grant(key, itemId, quantity)
	if not granted then
		return false, reason
	end
	return true
end

-- Removes quantity of itemId across stacks (e.g. crafting costs). All or nothing.
function InventoryService:Consume(player, itemId, quantity)
	local key = activeKey[player]
	if not key then
		return false, "NoLivingCharacter"
	end
	quantity = quantity or 1
	if store:CountOf(key, itemId) < quantity then
		return false, "InsufficientQuantity"
	end
	local remaining = quantity
	for _, item in ipairs(store:GetContainer(key)) do
		if remaining == 0 then
			break
		end
		if item.itemId == itemId then
			local take = math.min(item.quantity, remaining)
			store:Remove(item.uid, take)
			remaining = remaining - take
		end
	end
	return true
end

-- Removes one item instance (or part of a stack) the player carries.
function InventoryService:RemoveItem(player, uid, quantity)
	local key = activeKey[player]
	local item = store:GetItem(uid)
	if not key or not item or item.container ~= key then
		return false, "NotOwner"
	end
	return store:Remove(uid, quantity)
end

return InventoryService
