--[[
	FacilityService (GDD §12)

	Faction facilities built on world build zones (parts tagged "BuildZone", attributes
	ZoneId and Territory). Members deposit materials and do build work together. Once
	operational a facility provides its functions (crafting stations so far), takes
	combat damage during PDs, can be repaired, destroyed or captured, and persists
	between PDs.

	Public API:
		FacilityService:GetEngine()
		FacilityService:SetBuildRule(fn(territory, faction) -> boolean)
		FacilityService:SetCaptureGate(fn(territory) -> boolean)
		FacilityService.OwnerChanged:Connect(fn(facilityId, newFaction, oldFaction, source))
		FacilityService.StateChanged:Connect(fn(facilityId, state))
		FacilityService.TerritoryContested:Connect(fn(territory, contested))

	Staff (ManageFacilities, Loreteam):
		/facility list
		/facility <id> owner <faction> | health <n> | finish | destroy | remove
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local Facilities = require(ReplicatedStorage.Shared.Territory.Config.Facilities)
local TerritoryConfig = require(ReplicatedStorage.Shared.Territory.TerritoryConfig)

local Production = script.Parent.Parent.Production
local Channels = require(Production.Channels)
local Deps = require(Production.ProductionDeps)
local WorldStore = require(Production.WorldStore)
local FacilityEngine = require(script.Parent.FacilityEngine)

local ZONE_TAG = "BuildZone"
local STORE_KEY = "facilities"
local MANAGE = "ManageFacilities"
local S = FacilityEngine.State

local FacilityService = {}
FacilityService.OwnerChanged = Signal.new()
FacilityService.StateChanged = Signal.new()
FacilityService.TerritoryContested = Signal.new()

local engine
local zones = {} -- zoneId -> { part, territory }
local models = {} -- facilityId -> Model
local unregisterStructure = {} -- facilityId -> fn
local stationIds = {} -- facilityId -> { stationId }
local buildRule = nil
local captureGate = nil
local contestedTerritories = {} -- territory -> true
local dirty = false
local folder

local STATE_COLOURS = {
	[S.UnderConstruction] = Color3.fromRGB(200, 170, 90),
	[S.Operational] = Color3.fromRGB(120, 160, 120),
	[S.Damaged] = Color3.fromRGB(170, 110, 80),
	[S.Destroyed] = Color3.fromRGB(60, 60, 60),
}

local function now()
	return os.time()
end

local function CraftingService()
	return Deps.service("CraftingService")
end

local function zoneCFrame(zoneId)
	local zone = zones[zoneId]
	return zone and zone.part.CFrame or nil
end

local function facilityPosition(id)
	local model = models[id]
	return model and model:GetPivot().Position or nil
end

local function broadcast(id)
	local snap = engine:Snapshot(id)
	if snap then
		Net.FireAll("FacilityState", snap)
	end
	dirty = true
end

local function refreshStations(id)
	local crafting = CraftingService()
	if not crafting then
		return
	end
	for _, stationId in ipairs(stationIds[id] or {}) do
		crafting:UnregisterStation(stationId)
	end
	stationIds[id] = {}
	local f = engine:Get(id)
	local position = facilityPosition(id)
	if not f or not position then
		return
	end
	for _, stationType in ipairs(engine:StationsOf(id)) do
		local stationId = id .. ":" .. stationType
		crafting:RegisterStation(stationId, {
			type = stationType,
			position = position,
			faction = f.faction,
			operational = engine:IsFunctional(id),
		})
		table.insert(stationIds[id], stationId)
	end
end

local onDamage

local function registerStructure(id)
	if unregisterStructure[id] then
		unregisterStructure[id]()
		unregisterStructure[id] = nil
	end
	local CombatService = Deps.service("CombatService")
	local f = engine:Get(id)
	local model = models[id]
	if not CombatService or not CombatService.RegisterStructure or not f or not model or f.state == S.Destroyed then
		return
	end
	unregisterStructure[id] = CombatService:RegisterStructure(model, {
		faction = f.faction,
		onDamage = function(attacker, amount, actionId)
			onDamage(id, attacker, amount, actionId)
		end,
	})
end

local function styleModel(id)
	local model = models[id]
	local f, def = engine:Get(id)
	if not model or not f then
		return
	end
	model:SetAttribute("FacilityId", id)
	model:SetAttribute("FacilityType", f.typeId)
	model:SetAttribute("Faction", f.faction)
	model:SetAttribute("State", f.state)
	model:SetAttribute("Health", f.health)
	model:SetAttribute("MaxHealth", def.maxHealth)
	local block = model:FindFirstChild("Placeholder")
	if block then
		block.Color = STATE_COLOURS[f.state] or block.Color
		block.Transparency = (f.state == S.UnderConstruction) and 0.5 or 0
	end
end

local function spawnModel(id)
	local f, def = engine:Get(id)
	local cf = zoneCFrame(f.zoneId)
	if not cf then
		return
	end
	local template = ServerStorage:FindFirstChild("FacilityModels") and ServerStorage.FacilityModels:FindFirstChild(f.typeId)
	local model
	if template then
		model = template:Clone()
	else
		model = Instance.new("Model")
		local block = Instance.new("Part")
		block.Name = "Placeholder"
		block.Anchored = true
		local size = def.size or { x = 12, y = 8, z = 12 }
		block.Size = Vector3.new(size.x, size.y, size.z)
		block.CFrame = cf * CFrame.new(0, size.y / 2, 0)
		block.Parent = model
		model.PrimaryPart = block
	end
	model.Name = id
	if template then
		model:PivotTo(cf)
	end
	model.Parent = folder
	models[id] = model
	styleModel(id)
end

local function destroyModel(id)
	if unregisterStructure[id] then
		unregisterStructure[id]()
		unregisterStructure[id] = nil
	end
	if models[id] then
		models[id]:Destroy()
		models[id] = nil
	end
end

local function afterChange(id, previousState)
	local f = engine:Get(id)
	styleModel(id)
	refreshStations(id)
	broadcast(id)
	if f and f.state ~= previousState then
		FacilityService.StateChanged:Fire(id, f.state)
		if f.state == S.Destroyed then
			registerStructure(id) -- unregisters
		end
	end
end

function onDamage(id, attacker, amount, actionId)
	local f = engine:Get(id)
	if not f then
		return
	end
	local before = f.state
	local ok, state = engine:Damage(id, amount)
	if not ok then
		return
	end
	afterChange(id, before)
	if state == S.Destroyed and before ~= S.Destroyed then
		Deps.audit(attacker, "Facility.Destroyed", { facilityId = id, typeId = f.typeId, faction = f.faction, actionId = actionId })
	end
end

-- For a capture the engine has already moved ownership; staff changes go through here.
local function changeOwner(id, old, newFaction, source, actor)
	local f = engine:Get(id)
	if source ~= "capture" then
		engine:SetOwner(id, newFaction)
	end
	registerStructure(id)
	afterChange(id, f.state)
	Deps.audit(actor, "Facility.OwnerChanged", { facilityId = id, from = old, to = newFaction, source = source })
	FacilityService.OwnerChanged:Fire(id, newFaction, old, source)
end

-- Player actions -------------------------------------------------------------

local function nearFacility(player, id)
	return Deps.distanceTo(player, facilityPosition(id)) <= TerritoryConfig.Range + 20
end

local function baseCheck(player)
	if not Deps.pdAllows(TerritoryConfig.BuildRequiresActivePD) then
		return nil, "NoActivePD"
	end
	local character = Deps.character(player)
	if not character then
		return nil, "NoLivingCharacter"
	end
	return character
end

function FacilityService:Place(player, typeId, zoneId)
	if type(typeId) ~= "string" or type(zoneId) ~= "string" then
		return false, "BadRequest"
	end
	local character, err = baseCheck(player)
	if not character then
		return false, err
	end
	local zone = zones[zoneId]
	if not zone then
		return false, "UnknownZone"
	end
	if Deps.distanceTo(player, zone.part.Position) > TerritoryConfig.Range + 20 then
		return false, "OutOfRange"
	end
	local buildOk = nil
	if buildRule and zone.territory then
		buildOk = buildRule(zone.territory, character.faction)
	end
	local ruin = engine:InZone(zoneId)
	local ok, idOrErr = engine:Place(typeId, zoneId, zone.territory, {
		faction = character.faction,
		canBuild = Deps.roleHas(character, "build"),
		buildOk = buildOk,
	}, now())
	if not ok then
		return false, idOrErr
	end
	if ruin then
		-- Rebuilding on a ruin replaces it.
		destroyModel(ruin.id)
		refreshStations(ruin.id)
	end
	spawnModel(idOrErr)
	registerStructure(idOrErr)
	broadcast(idOrErr)
	Deps.audit(player, "Facility.Placed", { facilityId = idOrErr, typeId = typeId, zoneId = zoneId, characterId = character.id })
	return true, idOrErr
end

function FacilityService:Contribute(player, id, itemId, qty)
	if type(id) ~= "string" or type(itemId) ~= "string" or type(qty) ~= "number" or qty < 1 or qty ~= math.floor(qty) then
		return false, "BadRequest"
	end
	local character, err = baseCheck(player)
	if not character then
		return false, err
	end
	if not nearFacility(player, id) then
		return false, "OutOfRange"
	end
	local inventory = Deps.inventory()
	if not inventory then
		return false, "InventoryUnavailable"
	end
	local canWork, reason = engine:CanWork(id, character.faction)
	if not canWork then
		return false, reason
	end
	local need = (engine:Outstanding(id) or {})[itemId] or 0
	local take = math.min(need, qty, inventory:Count(player, itemId))
	if take < 1 then
		return false, need < 1 and "NotNeeded" or "MissingMaterials"
	end
	-- Checked above with no yield in between, so both steps succeed together.
	local before = engine:Get(id).state
	local consumed, consumeErr = inventory:Consume(player, itemId, take)
	if not consumed then
		return false, consumeErr
	end
	local _, accepted = engine:Contribute(id, character.faction, itemId, take)
	afterChange(id, before)
	Deps.audit(player, "Facility.Contribute", { facilityId = id, itemId = itemId, qty = accepted, characterId = character.id })
	return true, accepted
end

local function startWork(player, id, kind)
	if type(id) ~= "string" then
		return false, "BadRequest"
	end
	local character, err = baseCheck(player)
	if not character then
		return false, err
	end
	local function valid()
		local c = Deps.character(player)
		if not c or c.id ~= character.id then
			return false, "NoLivingCharacter"
		end
		if not Deps.pdAllows(TerritoryConfig.BuildRequiresActivePD) then
			return false, "NoActivePD"
		end
		if not nearFacility(player, id) then
			return false, "OutOfRange"
		end
		if kind == "Build" then
			return engine:CanWork(id, c.faction)
		end
		local ok, reason = engine:CanRepair(id, c.faction)
		if not ok then
			return false, reason
		end
		local inventory = Deps.inventory()
		for itemId, qty in pairs(TerritoryConfig.RepairCost) do
			if not inventory or inventory:Count(player, itemId) < qty then
				return false, "MissingMaterials"
			end
		end
		return true
	end
	local ok, reason = valid()
	if not ok then
		return false, reason
	end
	local started, busy = Channels.Start(player, {
		kind = kind,
		id = id,
		duration = TerritoryConfig.WorkSeconds,
		stillValid = valid,
		onComplete = function()
			local before = engine:Get(id).state
			if kind == "Build" then
				engine:Work(id, character.faction, TerritoryConfig.WorkPerChannel)
			else
				local inventory = Deps.inventory()
				for itemId, qty in pairs(TerritoryConfig.RepairCost) do
					inventory:Consume(player, itemId, qty)
				end
				engine:Repair(id, character.faction, TerritoryConfig.RepairPerChannel)
			end
			afterChange(id, before)
			Deps.audit(player, "Facility." .. kind, { facilityId = id, characterId = character.id })
			return true
		end,
	})
	if not started then
		return false, busy
	end
	return true, TerritoryConfig.WorkSeconds
end

-- Capture loop -----------------------------------------------------------------

local function presentAround(position, radius)
	local present = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local c = Deps.character(player)
		if c and Deps.distanceTo(player, position) <= radius then
			present[c.faction] = (present[c.faction] or 0) + 1
		end
	end
	return present
end

local function captureTick(dt)
	if not Deps.pdAllows(true) then
		return
	end
	local contestedNow = {}
	for _, snap in ipairs(engine:List()) do
		local f, def = engine:Get(snap.id)
		local position = facilityPosition(snap.id)
		if def.capturable and position then
			local allowed = true
			if captureGate and f.territory then
				allowed = captureGate(f.territory)
			end
			local oldFaction = f.faction
			local event, newOwner = engine:CaptureTick(snap.id, presentAround(position, def.captureRadius), dt, allowed)
			if event == "Captured" then
				changeOwner(snap.id, oldFaction, newOwner, "capture", nil)
			elseif event then
				broadcast(snap.id)
			end
			if def.anchor and f.territory and f.capture then
				contestedNow[f.territory] = true
			end
		end
	end
	for territory in pairs(contestedTerritories) do
		if not contestedNow[territory] then
			contestedTerritories[territory] = nil
			FacilityService.TerritoryContested:Fire(territory, false)
		end
	end
	for territory in pairs(contestedNow) do
		if not contestedTerritories[territory] then
			contestedTerritories[territory] = true
			FacilityService.TerritoryContested:Fire(territory, true)
		end
	end
end

-- Staff ------------------------------------------------------------------------

local function staff(actor, action, details, fn)
	if not Deps.hasStaffPermission(actor, MANAGE) then
		return false, "NotPermitted"
	end
	local ok, err = fn()
	if ok then
		Deps.audit(actor, action, details)
	end
	return ok, err
end

function FacilityService:AdminSetOwner(actor, id, faction)
	if not WorldConfig.isValidFaction(faction) then
		return false, "UnknownFaction"
	end
	if not engine:Get(id) then
		return false, "UnknownFacility"
	end
	return staff(actor, "Facility.AdminOwner", { facilityId = id, faction = faction }, function()
		changeOwner(id, engine:Get(id).faction, faction, "staff", actor)
		return true
	end)
end

function FacilityService:AdminSetHealth(actor, id, health)
	return staff(actor, "Facility.AdminHealth", { facilityId = id, health = health }, function()
		local f = engine:Get(id)
		if not f then
			return false, "UnknownFacility"
		end
		local before = f.state
		local ok, err = engine:SetHealth(id, health)
		if ok then
			if before == S.Destroyed and f.state ~= S.Destroyed then
				registerStructure(id)
			end
			afterChange(id, before)
		end
		return ok, err
	end)
end

function FacilityService:AdminFinish(actor, id)
	return staff(actor, "Facility.AdminFinish", { facilityId = id }, function()
		local f = engine:Get(id)
		if not f then
			return false, "UnknownFacility"
		end
		local before = f.state
		engine:FinishNow(id)
		registerStructure(id)
		afterChange(id, before)
		return true
	end)
end

function FacilityService:AdminRemove(actor, id)
	return staff(actor, "Facility.AdminRemove", { facilityId = id }, function()
		local ok, err = engine:Remove(id)
		if ok then
			destroyModel(id)
			refreshStations(id)
			Net.FireAll("FacilityState", { id = id, removed = true })
			dirty = true
		end
		return ok, err
	end)
end

local function registerCommands()
	local StaffCommandService = Deps.service("StaffCommandService")
	if not StaffCommandService or not StaffCommandService.RegisterCommand then
		return
	end
	StaffCommandService:RegisterCommand("facility", {
		usage = { "/facility list", "/facility <id> owner <faction>|health <n>|finish|destroy|remove" },
		permissions = { MANAGE },
		run = function(player, args)
			if not Deps.hasStaffPermission(player, MANAGE) then
				return "Not permitted."
			end
			if args[1] == "list" or args[1] == nil then
				local lines = {}
				for _, f in ipairs(engine:List()) do
					table.insert(lines, ("%s %s [%s] %s %d/%d%s"):format(f.id, f.typeId, f.faction, f.state, f.health, f.maxHealth,
						f.capture and (" capture " .. f.capture.faction .. " " .. math.floor(f.capture.progress * 100) .. "%") or ""))
				end
				return #lines > 0 and table.concat(lines, "\n") or "No facilities."
			end
			local id, verb, value = args[1], args[2], args[3]
			local ok, err
			if verb == "owner" then
				ok, err = FacilityService:AdminSetOwner(player, id, value)
			elseif verb == "health" then
				ok, err = FacilityService:AdminSetHealth(player, id, tonumber(value))
			elseif verb == "destroy" then
				ok, err = FacilityService:AdminSetHealth(player, id, 0)
			elseif verb == "finish" then
				ok, err = FacilityService:AdminFinish(player, id)
			elseif verb == "remove" then
				ok, err = FacilityService:AdminRemove(player, id)
			else
				return "Usage: /facility <id> owner <faction>|health <n>|finish|destroy|remove"
			end
			return ok and "Done" or ("Failed: " .. tostring(err))
		end,
	})
end

-- Lifecycle ---------------------------------------------------------------------

function FacilityService:GetEngine()
	return engine
end

function FacilityService:SetBuildRule(fn)
	buildRule = fn
end

function FacilityService:SetCaptureGate(fn)
	captureGate = fn
end

local function addZone(part)
	local zoneId = part:GetAttribute("ZoneId") or part:GetFullName()
	zones[zoneId] = { part = part, territory = part:GetAttribute("Territory") }
	local f = engine:InZone(zoneId)
	if f and not models[f.id] then
		spawnModel(f.id)
		registerStructure(f.id)
		refreshStations(f.id)
	end
end

function FacilityService:Init()
	engine = FacilityEngine.new({
		types = Facilities,
		config = TerritoryConfig,
		newId = function()
			return "fac-" .. HttpService:GenerateGUID(false):sub(1, 8):lower()
		end,
	})
	registerCommands()
end

function FacilityService:Start()
	folder = Instance.new("Folder")
	folder.Name = "Facilities"
	folder.Parent = workspace

	engine:Load(WorldStore.Load(STORE_KEY))
	for _, part in ipairs(CollectionService:GetTagged(ZONE_TAG)) do
		addZone(part)
	end
	CollectionService:GetInstanceAddedSignal(ZONE_TAG):Connect(addZone)

	Net.OnInvoke("FacilityPlace", function(player, typeId, zoneId)
		return FacilityService:Place(player, typeId, zoneId)
	end, { rateLimit = 2 })
	Net.OnInvoke("FacilityContribute", function(player, id, itemId, qty)
		return FacilityService:Contribute(player, id, itemId, qty)
	end, { rateLimit = 6 })
	Net.OnInvoke("FacilityWork", function(player, id)
		return startWork(player, id, "Build")
	end, { rateLimit = 4 })
	Net.OnInvoke("FacilityRepair", function(player, id)
		return startWork(player, id, "Repair")
	end, { rateLimit = 4 })

	task.spawn(function()
		while true do
			local dt = task.wait(TerritoryConfig.CaptureTickInterval)
			captureTick(dt)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(60)
			if dirty then
				dirty = false
				WorldStore.Save(STORE_KEY, engine:Serialize())
			end
		end
	end)
	local PDEventService = Deps.service("PDEventService")
	if PDEventService then
		PDEventService.EventEnded:Connect(function()
			WorldStore.Save(STORE_KEY, engine:Serialize())
		end)
	end
	game:BindToClose(function()
		WorldStore.Save(STORE_KEY, engine:Serialize())
	end)
end

return FacilityService
