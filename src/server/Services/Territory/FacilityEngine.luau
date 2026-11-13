--[[
	FacilityEngine

	Pure facility rules (GDD §12): placement, cooperative construction, damage,
	repair, capture and staff overrides. No Roblox APIs.

	States:
		UnderConstruction -> Operational <-> Damaged -> Destroyed
		Capture moves an Operational/Damaged facility to the attacking faction.

	deps:
		types   table from Territory/Config/Facilities
		config  TerritoryConfig
		newId   optional function() -> string
]]

local FacilityEngine = {}
FacilityEngine.__index = FacilityEngine

FacilityEngine.State = {
	UnderConstruction = "UnderConstruction",
	Operational = "Operational",
	Damaged = "Damaged",
	Destroyed = "Destroyed",
}
local S = FacilityEngine.State

local function contains(list, value)
	for _, v in ipairs(list or {}) do
		if v == value then
			return true
		end
	end
	return false
end

function FacilityEngine.new(deps)
	assert(deps and deps.types and deps.config, "FacilityEngine needs types and config")
	for key, def in pairs(deps.types) do
		assert(type(def.displayName) == "string", ("facility %s needs displayName"):format(key))
		assert(type(def.factions) == "table", ("facility %s needs factions"):format(key))
		assert(type(def.cost) == "table", ("facility %s needs cost"):format(key))
		assert(type(def.buildPoints) == "number" and def.buildPoints > 0, ("facility %s needs buildPoints"):format(key))
		assert(type(def.maxHealth) == "number" and def.maxHealth > 0, ("facility %s needs maxHealth"):format(key))
		if def.capturable then
			assert(type(def.captureTime) == "number" and def.captureTime > 0, ("facility %s needs captureTime"):format(key))
			assert(type(def.captureRadius) == "number" and def.captureRadius > 0, ("facility %s needs captureRadius"):format(key))
		end
	end
	local self
	self = setmetatable({
		_counter = 0,
		_types = deps.types,
		_config = deps.config,
		_newId = deps.newId or function()
			self._counter = self._counter + 1
			return "fac-" .. self._counter
		end,
		_facilities = {},
	}, FacilityEngine)
	return self
end

function FacilityEngine:Get(id)
	local f = self._facilities[id]
	return f, f and self._types[f.typeId]
end

function FacilityEngine:CountFor(faction)
	local n = 0
	for _, f in pairs(self._facilities) do
		if f.faction == faction and f.state ~= S.Destroyed then
			n = n + 1
		end
	end
	return n
end

function FacilityEngine:InZone(zoneId)
	for _, f in pairs(self._facilities) do
		if f.zoneId == zoneId then
			return f
		end
	end
	return nil
end

--[[
	ctx:
		faction     builder's faction
		canBuild    boolean from the builder's role permission
		buildOk     boolean from the territory rule (nil = no territory rule)
]]
function FacilityEngine:CanPlace(typeId, zoneId, ctx)
	local def = self._types[typeId]
	if not def then
		return false, "UnknownFacility"
	end
	if not self._config.BuildingFactions[ctx.faction] or not contains(def.factions, ctx.faction) then
		return false, "FactionNotAllowed"
	end
	if not ctx.canBuild then
		return false, "MissingPermission"
	end
	if ctx.buildOk == false then
		return false, "TerritoryDenied"
	end
	local existing = self:InZone(zoneId)
	if existing and existing.state ~= S.Destroyed then
		return false, "ZoneOccupied"
	end
	local cap = self._config.MaxFacilitiesPerFaction
	if cap and self:CountFor(ctx.faction) >= cap then
		return false, "FacilityCap"
	end
	return true
end

function FacilityEngine:Place(typeId, zoneId, territory, ctx, now)
	local ok, err = self:CanPlace(typeId, zoneId, ctx)
	if not ok then
		return false, err
	end
	local existing = self:InZone(zoneId)
	if existing then
		-- Rebuilding on a ruin replaces it.
		self._facilities[existing.id] = nil
	end
	local def = self._types[typeId]
	local id = self._newId()
	self._facilities[id] = {
		id = id,
		typeId = typeId,
		zoneId = zoneId,
		territory = territory,
		faction = ctx.faction,
		state = S.UnderConstruction,
		health = math.floor(def.maxHealth * self._config.ConstructionHealthShare),
		contributed = {},
		buildProgress = 0,
		capture = nil,
		createdAt = now,
	}
	return true, id
end

-- Remaining materials for construction: { [itemId] = qty }.
function FacilityEngine:Outstanding(id)
	local f, def = self:Get(id)
	if not f then
		return nil
	end
	local out = {}
	for itemId, qty in pairs(def.cost) do
		local left = qty - (f.contributed[itemId] or 0)
		if left > 0 then
			out[itemId] = left
		end
	end
	return out
end

-- Returns how many of qty were accepted (never more than still needed).
function FacilityEngine:Contribute(id, faction, itemId, qty)
	local f = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	if f.faction ~= faction then
		return false, "NotYourFacility"
	end
	if f.state ~= S.UnderConstruction then
		return false, "NotUnderConstruction"
	end
	local need = (self:Outstanding(id))[itemId] or 0
	if need <= 0 then
		return false, "NotNeeded"
	end
	local take = math.min(need, qty)
	f.contributed[itemId] = (f.contributed[itemId] or 0) + take
	self:_maybeFinish(f)
	return true, take
end

function FacilityEngine:_maybeFinish(f)
	local def = self._types[f.typeId]
	if f.state == S.UnderConstruction and next(self:Outstanding(f.id)) == nil and f.buildProgress >= def.buildPoints then
		f.state = S.Operational
		f.health = def.maxHealth
		return true
	end
	return false
end

function FacilityEngine:CanWork(id, faction)
	local f = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	if f.faction ~= faction then
		return false, "NotYourFacility"
	end
	if f.state ~= S.UnderConstruction then
		return false, "NotUnderConstruction"
	end
	return true
end

-- Adds build points. Returns ok, finished.
function FacilityEngine:Work(id, faction, points)
	local ok, err = self:CanWork(id, faction)
	if not ok then
		return false, err
	end
	local f, def = self:Get(id)
	-- Health grows with progress, keeping any damage already taken.
	local before = f.buildProgress
	f.buildProgress = math.min(def.buildPoints, f.buildProgress + points)
	local share = self._config.ConstructionHealthShare
	local gained = (f.buildProgress - before) / def.buildPoints
	f.health = math.min(def.maxHealth, f.health + math.floor(def.maxHealth * (1 - share) * gained))
	return true, self:_maybeFinish(f)
end

function FacilityEngine:_settleHealthState(f)
	local def = self._types[f.typeId]
	if f.health <= 0 then
		f.health = 0
		f.state = S.Destroyed
		f.capture = nil
	elseif f.state ~= S.UnderConstruction then
		f.state = (f.health < def.maxHealth * self._config.DamagedThreshold) and S.Damaged or S.Operational
	end
end

-- Returns ok, newState. Same-faction checks are done by combat.
function FacilityEngine:Damage(id, amount)
	local f = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	if f.state == S.Destroyed then
		return false, "Destroyed"
	end
	if type(amount) ~= "number" or amount <= 0 then
		return false, "InvalidAmount"
	end
	f.health = f.health - amount
	self:_settleHealthState(f)
	return true, f.state
end

function FacilityEngine:CanRepair(id, faction)
	local f, def = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	if f.faction ~= faction then
		return false, "NotYourFacility"
	end
	if f.state ~= S.Operational and f.state ~= S.Damaged then
		return false, "CannotRepair"
	end
	if f.health >= def.maxHealth then
		return false, "FullHealth"
	end
	return true
end

function FacilityEngine:Repair(id, faction, amount)
	local ok, err = self:CanRepair(id, faction)
	if not ok then
		return false, err
	end
	local f, def = self:Get(id)
	f.health = math.min(def.maxHealth, f.health + amount)
	self:_settleHealthState(f)
	return true, f.state
end

--[[
	Advances capture by dt seconds. present = { [faction] = livingCount } inside the
	capture radius. captureAllowed = false (e.g. a locked territory) freezes capture.
	Returns event: nil | "Progress" | "Contested" | "Captured", plus the new owner.
]]
function FacilityEngine:CaptureTick(id, present, dt, captureAllowed)
	local f, def = self:Get(id)
	if not f or not def.capturable then
		return nil
	end
	if f.state ~= S.Operational and f.state ~= S.Damaged then
		f.capture = nil
		return nil
	end
	local attackers, defenders = {}, (present[f.faction] or 0)
	for faction, count in pairs(present) do
		if faction ~= f.faction and count > 0 and self._config.BuildingFactions[faction] then
			table.insert(attackers, faction)
		end
	end
	if captureAllowed == false then
		f.capture = nil
		return nil
	end
	if #attackers == 0 then
		if f.capture then
			f.capture.progress = f.capture.progress - dt * self._config.CaptureDecayRate / def.captureTime
			if f.capture.progress <= 0 then
				f.capture = nil
			end
			return "Progress"
		end
		return nil
	end
	if defenders > 0 or #attackers > 1 then
		if f.capture then
			f.capture.contested = true
		end
		return "Contested"
	end
	local attacker = attackers[1]
	if not f.capture or f.capture.faction ~= attacker then
		f.capture = { faction = attacker, progress = 0 }
	end
	f.capture.contested = false
	f.capture.progress = f.capture.progress + dt / def.captureTime
	if f.capture.progress >= 1 then
		f.faction = attacker
		f.capture = nil
		return "Captured", attacker
	end
	return "Progress"
end

-- Staff overrides (GDD §12.4: Loreteam-recognised outcomes).
function FacilityEngine:SetOwner(id, faction)
	local f = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	f.faction = faction
	f.capture = nil
	return true
end

function FacilityEngine:SetHealth(id, health)
	local f, def = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	if type(health) ~= "number" or health < 0 then
		return false, "InvalidAmount"
	end
	f.health = math.min(def.maxHealth, health)
	if f.state == S.Destroyed and f.health > 0 then
		f.state = S.Operational
	end
	self:_settleHealthState(f)
	return true
end

function FacilityEngine:FinishNow(id)
	local f, def = self:Get(id)
	if not f then
		return false, "UnknownFacility"
	end
	f.state = S.Operational
	f.health = def.maxHealth
	f.buildProgress = def.buildPoints
	return true
end

function FacilityEngine:Remove(id)
	if not self._facilities[id] then
		return false, "UnknownFacility"
	end
	self._facilities[id] = nil
	return true
end

-- Stations this facility provides: list of Stations keys.
function FacilityEngine:StationsOf(id)
	local _, def = self:Get(id)
	local out = {}
	for _, p in ipairs(def and def.provides or {}) do
		local station = p:match("^station:(.+)$")
		if station then
			table.insert(out, station)
		end
	end
	return out
end

function FacilityEngine:IsFunctional(id)
	local f = self:Get(id)
	return f ~= nil and f.state == S.Operational
end

function FacilityEngine:Snapshot(id)
	local f, def = self:Get(id)
	if not f then
		return nil
	end
	return {
		id = f.id,
		typeId = f.typeId,
		displayName = def.displayName,
		zoneId = f.zoneId,
		territory = f.territory,
		faction = f.faction,
		state = f.state,
		health = f.health,
		maxHealth = def.maxHealth,
		buildProgress = f.buildProgress,
		buildPoints = def.buildPoints,
		outstanding = self:Outstanding(id),
		capture = f.capture and { faction = f.capture.faction, progress = f.capture.progress, contested = f.capture.contested } or nil,
	}
end

function FacilityEngine:List()
	local out = {}
	for id in pairs(self._facilities) do
		table.insert(out, self:Snapshot(id))
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function FacilityEngine:Serialize()
	local out = {}
	for id, f in pairs(self._facilities) do
		out[id] = {
			typeId = f.typeId,
			zoneId = f.zoneId,
			territory = f.territory,
			faction = f.faction,
			state = f.state,
			health = f.health,
			contributed = f.contributed,
			buildProgress = f.buildProgress,
			createdAt = f.createdAt,
		}
	end
	return out
end

function FacilityEngine:Load(data)
	for id, saved in pairs(data or {}) do
		if self._types[saved.typeId] then
			self._facilities[id] = {
				id = id,
				typeId = saved.typeId,
				zoneId = saved.zoneId,
				territory = saved.territory,
				faction = saved.faction,
				state = saved.state,
				health = saved.health,
				contributed = saved.contributed or {},
				buildProgress = saved.buildProgress or 0,
				createdAt = saved.createdAt,
			}
			local n = tonumber(tostring(id):match("^fac%-(%d+)$"))
			if n and n > self._counter then
				self._counter = n
			end
		end
	end
end

return FacilityEngine
