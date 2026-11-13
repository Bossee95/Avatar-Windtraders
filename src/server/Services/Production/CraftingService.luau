--[[
	CraftingService (GDD §11)

	Recipes are crafted at stations over a server-timed channel. On completion the
	inputs are consumed and the outputs granted in one non-yielding step, rolled back
	if any part fails, so materials are never lost and outputs never duplicated.

	Crafting gives items only. It never touches ranks, Trials, weapon kits or G
	abilities: a crafted weapon can be held and traded by anyone, but only a character
	with a Loreteam-assigned kit can use its moveset (CombatService checks on equip).

	Stations come from world parts tagged "CraftingStation" (attributes StationType,
	StationId?, Faction?) or from other systems (facilities) via RegisterStation.

	Public API:
		CraftingService:GetEngine()
		CraftingService:RegisterStation(stationId, { type, position, faction?, operational? })
		CraftingService:SetStationOperational(stationId, operational)
		CraftingService:UnregisterStation(stationId)
		CraftingService:ListRecipes(player, stationId) -> { recipe view }
		CraftingService:AdminSetRecipeLocked(actor, recipeId, faction?, locked) -> ok, err
		CraftingService.Crafted:Connect(fn(player, characterId, recipeId, stationId))

	AdminSetRecipeLocked requires the ManageRecipes permission.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ProductionConfig = require(ReplicatedStorage.Shared.Production.ProductionConfig)
local Recipes = require(ReplicatedStorage.Shared.Production.Config.Recipes)
local Stations = require(ReplicatedStorage.Shared.Production.Config.Stations)

local Channels = require(script.Parent.Channels)
local CraftingEngine = require(script.Parent.CraftingEngine)
local Deps = require(script.Parent.ProductionDeps)
local WorldStore = require(script.Parent.WorldStore)

local STATION_TAG = "CraftingStation"
local LOCKS_KEY = "recipeLocks"
local MANAGE = "ManageRecipes"

local CraftingService = {}
CraftingService.Crafted = Signal.new()

local engine
local stations = {} -- stationId -> { type, position, faction?, operational }

local function stationIdOf(instance)
	return instance:GetAttribute("StationId") or instance:GetFullName()
end

function CraftingService:RegisterStation(stationId, info)
	assert(Stations[info.type], "unknown station type " .. tostring(info.type))
	stations[stationId] = {
		type = info.type,
		position = info.position,
		faction = info.faction,
		operational = info.operational ~= false,
	}
end

function CraftingService:SetStationOperational(stationId, operational)
	local s = stations[stationId]
	if s then
		s.operational = operational == true
	end
end

function CraftingService:UnregisterStation(stationId)
	stations[stationId] = nil
end

local function ctxFor(player, character, station)
	local inventory = Deps.inventory()
	return {
		faction = character.faction,
		rank = character.rank,
		hasPermission = function(flag)
			return Deps.roleHas(character, flag)
		end,
		countOf = function(itemId)
			return inventory and inventory:Count(player, itemId) or 0
		end,
		station = station,
	}
end

local function check(player, recipeId, stationId)
	if not Deps.pdAllows(ProductionConfig.CraftRequiresActivePD) then
		return false, "NoActivePD"
	end
	local character = Deps.character(player)
	if not character then
		return false, "NoLivingCharacter"
	end
	if not Deps.inventory() then
		return false, "InventoryUnavailable"
	end
	local station = stations[stationId]
	if not station then
		return false, "UnknownStation"
	end
	if Deps.distanceTo(player, station.position) > ProductionConfig.CraftRange then
		return false, "OutOfRange"
	end
	return engine:Check(recipeId, ctxFor(player, character, station))
end

local function inventoryAdapter(player)
	local inventory = Deps.inventory()
	return {
		count = function(itemId)
			return inventory:Count(player, itemId)
		end,
		consume = function(itemId, qty)
			return inventory:Consume(player, itemId, qty)
		end,
		grant = function(itemId, qty)
			return inventory:Grant(player, itemId, qty)
		end,
		ungrant = function(itemId, qty)
			inventory:Consume(player, itemId, qty)
		end,
		unconsume = function(itemId, qty)
			inventory:Grant(player, itemId, qty)
		end,
	}
end

local function complete(player, recipeId, stationId, characterId)
	local character = Deps.character(player)
	if not character or character.id ~= characterId then
		return false, "NoLivingCharacter"
	end
	local plan = engine:Plan(recipeId)
	local ok, err = CraftingEngine.Apply(plan, inventoryAdapter(player))
	if not ok then
		return false, err
	end
	Deps.audit(player, "Production.Craft", {
		characterId = characterId,
		recipeId = recipeId,
		stationId = stationId,
		consumed = plan.consume,
		granted = plan.grant,
	})
	CraftingService.Crafted:Fire(player, characterId, recipeId, stationId)
	local items = {}
	for _, g in ipairs(plan.grant) do
		items[g.item] = (items[g.item] or 0) + g.qty
	end
	return true, nil, items
end

function CraftingService:StartCraft(player, recipeId, stationId)
	if type(recipeId) ~= "string" or type(stationId) ~= "string" then
		return false, "BadRequest"
	end
	local ok, err = check(player, recipeId, stationId)
	if not ok then
		return false, err
	end
	local character = Deps.character(player)
	local recipe = engine:Get(recipeId)
	local started, busy = Channels.Start(player, {
		kind = "Craft",
		id = recipeId,
		duration = recipe.craftTime,
		stillValid = function()
			return check(player, recipeId, stationId)
		end,
		onComplete = function()
			return complete(player, recipeId, stationId, character.id)
		end,
	})
	if not started then
		return false, busy
	end
	return true, recipe.craftTime
end

function CraftingService:ListRecipes(player, stationId)
	local character = Deps.character(player)
	local station = stations[stationId]
	if not character or not station then
		return {}
	end
	return engine:ListFor(station.type, ctxFor(player, character, station))
end

function CraftingService:GetEngine()
	return engine
end

function CraftingService:AdminSetRecipeLocked(actor, recipeId, faction, locked)
	if not Deps.hasStaffPermission(actor, MANAGE) then
		return false, "NotPermitted"
	end
	local ok, err = engine:SetLocked(recipeId, faction, locked)
	if ok then
		Deps.audit(actor, "Production.RecipeLock", { recipeId = recipeId, faction = faction, locked = locked })
		WorldStore.Save(LOCKS_KEY, engine:SerializeLocks())
	end
	return ok, err
end

local function addInstance(instance)
	local stationType = instance:GetAttribute("StationType")
	if not Stations[stationType] then
		warn(("[Production] Station %s ignored: unknown StationType %s"):format(instance:GetFullName(), tostring(stationType)))
		return
	end
	CraftingService:RegisterStation(stationIdOf(instance), {
		type = stationType,
		position = Deps.positionOf(instance),
		faction = instance:GetAttribute("Faction"),
	})
end

function CraftingService:Init()
	engine = CraftingEngine.new({ recipes = Recipes, stations = Stations })
end

-- Warns about recipes naming items the inventory does not define.
local function checkItems()
	local inventory = Deps.inventory()
	local registry = inventory and inventory.GetRegistry and inventory:GetRegistry()
	if not registry then
		return
	end
	for recipeId, recipe in pairs(Recipes) do
		for itemId in pairs(recipe.inputs) do
			if not registry:Exists(itemId) then
				warn(("[Production] Recipe %s: unknown input item %s"):format(recipeId, itemId))
			end
		end
		for _, out in ipairs(recipe.outputs) do
			if not registry:Exists(out.item) then
				warn(("[Production] Recipe %s: unknown output item %s"):format(recipeId, out.item))
			end
		end
	end
end

function CraftingService:Start()
	checkItems()
	engine:LoadLocks(WorldStore.Load(LOCKS_KEY))

	for _, instance in ipairs(CollectionService:GetTagged(STATION_TAG)) do
		addInstance(instance)
	end
	CollectionService:GetInstanceAddedSignal(STATION_TAG):Connect(addInstance)
	CollectionService:GetInstanceRemovedSignal(STATION_TAG):Connect(function(instance)
		CraftingService:UnregisterStation(stationIdOf(instance))
	end)

	Net.OnInvoke("CraftStart", function(player, recipeId, stationId)
		return CraftingService:StartCraft(player, recipeId, stationId)
	end, { rateLimit = 4 })
	Net.OnInvoke("CraftList", function(player, stationId)
		if type(stationId) ~= "string" then
			return {}
		end
		return CraftingService:ListRecipes(player, stationId)
	end, { rateLimit = 4 })
end

return CraftingService
