--[[
	TerritoryEngine

	Pure territory control (GDD §13.1). A territory's controller changes when its
	anchor facility is captured (design doc §5.2) or by a Loreteam ruling. A ruling
	can lock a territory so capture can't change it. No Roblox APIs.

	deps:
		territories  table from Territory/Config/Territories
		config       TerritoryConfig
]]

local TerritoryEngine = {}
TerritoryEngine.__index = TerritoryEngine

function TerritoryEngine.new(deps)
	assert(deps and deps.territories and deps.config, "TerritoryEngine needs territories and config")
	local self = setmetatable({ _defs = deps.territories, _config = deps.config, _state = {} }, TerritoryEngine)
	for key, def in pairs(deps.territories) do
		self._state[key] = {
			controller = def.startingController,
			contested = false,
			locked = false,
			source = "config",
			since = 0,
			pending = nil,
		}
	end
	return self
end

function TerritoryEngine:Exists(key)
	return self._state[key] ~= nil
end

function TerritoryEngine:Get(key)
	return self._state[key]
end

function TerritoryEngine:Status(key)
	local s = self._state[key]
	if not s then
		return nil
	end
	if s.contested then
		return "Contested"
	end
	return s.controller and "Held" or "Neutral"
end

function TerritoryEngine:SetContested(key, contested)
	local s = self._state[key]
	if not s or s.contested == (contested == true) then
		return false
	end
	s.contested = contested == true
	return true
end

function TerritoryEngine:CaptureAllowed(key)
	local s = self._state[key]
	return s == nil or not s.locked
end

--[[
	Called when an anchor facility in this territory changes owner through capture.
	Returns "Changed" | "Pending" | "Locked" | nil.
]]
function TerritoryEngine:OnAnchorCaptured(key, faction, now)
	local s = self._state[key]
	if not s then
		return nil
	end
	if s.locked then
		return "Locked"
	end
	if not self._config.CaptureChangesTerritoryImmediately then
		s.pending = { faction = faction, at = now }
		return "Pending"
	end
	if s.controller == faction then
		return nil
	end
	s.controller = faction
	s.source = "capture"
	s.since = now
	s.pending = nil
	return "Changed"
end

-- Loreteam ruling. faction may be nil (neutral). locked: true/false/nil (unchanged).
function TerritoryEngine:Rule(key, faction, locked, now)
	local s = self._state[key]
	if not s then
		return false, "UnknownTerritory"
	end
	if faction ~= nil and not self._config.BuildingFactions[faction] then
		return false, "FactionNotAllowed"
	end
	local changed = s.controller ~= faction
	s.controller = faction
	s.source = "staff"
	s.since = now
	s.pending = nil
	if locked ~= nil then
		s.locked = locked == true
	end
	return true, changed
end

function TerritoryEngine:SetLocked(key, locked)
	local s = self._state[key]
	if not s then
		return false, "UnknownTerritory"
	end
	s.locked = locked == true
	return true
end

-- Gathering access for a node in this territory (TerritoryConfig.NodeAccess).
function TerritoryEngine:CanGather(key, faction)
	local s = self._state[key]
	if not s then
		return true
	end
	local mode = self._config.NodeAccess
	if mode == "Anyone" or s.controller == nil or s.controller == faction then
		return true
	end
	if mode == "ControllerOrContested" then
		return s.contested
	end
	return false
end

-- Building access in this territory (TerritoryConfig.BuildAccess).
function TerritoryEngine:CanBuild(key, faction)
	local s = self._state[key]
	if not s then
		return true
	end
	if s.controller == faction then
		return true
	end
	local mode = self._config.BuildAccess
	if mode == "OwnedOrNeutral" then
		return s.controller == nil
	elseif mode == "OwnedOrContested" then
		return s.contested
	end
	return false
end

function TerritoryEngine:Snapshot(key)
	local s = self._state[key]
	if not s then
		return nil
	end
	return {
		key = key,
		controller = s.controller,
		status = self:Status(key),
		locked = s.locked,
		source = s.source,
		since = s.since,
		pending = s.pending,
		landmark = self._defs[key].landmark == true,
		adjacent = self._defs[key].adjacent,
	}
end

function TerritoryEngine:List()
	local out = {}
	for key in pairs(self._state) do
		table.insert(out, self:Snapshot(key))
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

function TerritoryEngine:Serialize()
	local out = {}
	for key, s in pairs(self._state) do
		out[key] = { controller = s.controller, locked = s.locked, source = s.source, since = s.since, pending = s.pending }
	end
	return out
end

function TerritoryEngine:Load(data)
	for key, saved in pairs(data or {}) do
		local s = self._state[key]
		if s then
			s.controller = saved.controller
			s.locked = saved.locked == true
			s.source = saved.source or s.source
			s.since = saved.since or 0
			s.pending = saved.pending
		end
	end
end

return TerritoryEngine
