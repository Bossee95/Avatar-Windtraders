--[[
	TerritoryService (GDD §13.1)

	Who controls each territory. Control changes when a territory's anchor facility
	is captured (immediately by default, see TerritoryConfig) or by a Loreteam ruling,
	which can also lock a territory against capture. Control decides gathering and
	building access; it never changes ranks, kits or entitlements.

	Public API:
		TerritoryService:GetEngine()
		TerritoryService:GetController(key) -> faction?
		TerritoryService:Rule(actor, key, faction?, locked?) -> ok, err
		TerritoryService.ControllerChanged:Connect(fn(key, newFaction, oldFaction, source))

	Staff (ManageTerritory, Loreteam):
		/territory list
		/territory <key> set <faction|none> [lock]
		/territory <key> lock | unlock
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local Facilities = require(ReplicatedStorage.Shared.Territory.Config.Facilities)
local Territories = require(ReplicatedStorage.Shared.Territory.Config.Territories)
local TerritoryConfig = require(ReplicatedStorage.Shared.Territory.TerritoryConfig)

local Production = script.Parent.Parent.Production
local Deps = require(Production.ProductionDeps)
local WorldStore = require(Production.WorldStore)
local GatheringService = require(Production.GatheringService)
local FacilityService = require(script.Parent.FacilityService)
local TerritoryEngine = require(script.Parent.TerritoryEngine)

local STORE_KEY = "territories"
local MANAGE = "ManageTerritory"

local TerritoryService = {}
TerritoryService.ControllerChanged = Signal.new()

local engine

local function save()
	WorldStore.Save(STORE_KEY, engine:Serialize())
end

local function broadcast(key)
	local snap = engine:Snapshot(key)
	if snap then
		snap.displayName = WorldConfig.getPlaceName(key)
		Net.FireAll("TerritoryState", snap)
	end
end

function TerritoryService:GetEngine()
	return engine
end

function TerritoryService:GetController(key)
	local s = engine:Get(key)
	return s and s.controller or nil
end

function TerritoryService:Rule(actor, key, faction, locked)
	if not Deps.hasStaffPermission(actor, MANAGE) then
		return false, "NotPermitted"
	end
	local old = self:GetController(key)
	local ok, changed = engine:Rule(key, faction, locked, os.time())
	if not ok then
		return false, changed
	end
	Deps.audit(actor, "Territory.Ruling", { territory = key, from = old, to = faction, locked = locked })
	save()
	broadcast(key)
	if changed then
		TerritoryService.ControllerChanged:Fire(key, faction, old, "staff")
	end
	return true
end

function TerritoryService:SetLocked(actor, key, locked)
	if not Deps.hasStaffPermission(actor, MANAGE) then
		return false, "NotPermitted"
	end
	local ok, err = engine:SetLocked(key, locked)
	if ok then
		Deps.audit(actor, "Territory.Lock", { territory = key, locked = locked })
		save()
		broadcast(key)
	end
	return ok, err
end

local function registerCommands()
	local StaffCommandService = Deps.service("StaffCommandService")
	if not StaffCommandService or not StaffCommandService.RegisterCommand then
		return
	end
	StaffCommandService:RegisterCommand("territory", {
		usage = { "/territory list", "/territory <key> set <faction|none> [lock]", "/territory <key> lock|unlock" },
		permissions = { MANAGE },
		run = function(player, args)
			if not Deps.hasStaffPermission(player, MANAGE) then
				return "Not permitted."
			end
			if args[1] == nil or args[1] == "list" then
				local lines = {}
				for _, t in ipairs(engine:List()) do
					table.insert(lines, ("%s (%s): %s %s%s%s"):format(t.key, WorldConfig.getPlaceName(t.key), t.status,
						t.controller and WorldConfig.getFactionName(t.controller) or "", t.locked and " [locked]" or "",
						t.pending and (" pending " .. t.pending.faction) or ""))
				end
				return table.concat(lines, "\n")
			end
			local key, verb, value, extra = args[1], args[2], args[3], args[4]
			local ok, err
			if verb == "set" then
				local faction = (value ~= "none") and value or nil
				ok, err = TerritoryService:Rule(player, key, faction, extra == "lock" and true or nil)
			elseif verb == "lock" or verb == "unlock" then
				ok, err = TerritoryService:SetLocked(player, key, verb == "lock")
			else
				return "Usage: /territory <key> set <faction|none> [lock] | lock | unlock"
			end
			return ok and "Done" or ("Failed: " .. tostring(err))
		end,
	})
end

function TerritoryService:Init()
	for key in pairs(Territories) do
		if not WorldConfig.Places[key] then
			warn(("[Territory] %s has no WorldConfig.Places entry for its display name"):format(key))
		end
	end
	engine = TerritoryEngine.new({ territories = Territories, config = TerritoryConfig })
	registerCommands()
end

function TerritoryService:Start()
	engine:Load(WorldStore.Load(STORE_KEY))

	GatheringService:SetTerritoryRule(function(player, key)
		local character = Deps.character(player)
		return character ~= nil and engine:CanGather(key, character.faction)
	end)
	FacilityService:SetBuildRule(function(key, faction)
		return engine:CanBuild(key, faction)
	end)
	FacilityService:SetCaptureGate(function(key)
		return engine:CaptureAllowed(key)
	end)
	FacilityService.TerritoryContested:Connect(function(key, contested)
		if engine:SetContested(key, contested) then
			broadcast(key)
		end
	end)
	FacilityService.OwnerChanged:Connect(function(facilityId, newFaction, _, source)
		if source ~= "capture" then
			return
		end
		local f = FacilityService:GetEngine():Get(facilityId)
		local def = f and Facilities[f.typeId]
		if not def or not def.anchor or not f.territory then
			return
		end
		local old = TerritoryService:GetController(f.territory)
		local result = engine:OnAnchorCaptured(f.territory, newFaction, os.time())
		if result then
			Deps.audit(nil, "Territory.Capture", { territory = f.territory, facilityId = facilityId, faction = newFaction, result = result })
			save()
			broadcast(f.territory)
		end
		if result == "Changed" then
			TerritoryService.ControllerChanged:Fire(f.territory, newFaction, old, "capture")
		end
	end)

	Net.OnInvoke("TerritoryGetState", function()
		local list = engine:List()
		for _, t in ipairs(list) do
			t.displayName = WorldConfig.getPlaceName(t.key)
		end
		return list
	end, { rateLimit = 2 })
end

return TerritoryService
