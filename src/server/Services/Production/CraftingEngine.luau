--[[
	CraftingEngine

	Pure recipe rules (GDD §11.3): materials, station, faction, rank, permission and
	staff recipe locks. No Roblox APIs.

	This module has no access to weapon kits, rank setters or any other progression writer.
	Crafting produces items only (GDD §11.2).

	deps:
		recipes   table from Production/Config/Recipes
		stations  table from Production/Config/Stations
		itemExists optional function(itemId) -> boolean, to validate config at load
]]

local CraftingEngine = {}
CraftingEngine.__index = CraftingEngine

local ANY = "*"

function CraftingEngine.new(deps)
	assert(deps and deps.recipes and deps.stations, "CraftingEngine needs recipes and stations")
	local self = setmetatable({
		_recipes = deps.recipes,
		_stations = deps.stations,
		_locks = {}, -- recipeId -> { [factionKey | "*"] = true }
	}, CraftingEngine)
	for id, recipe in pairs(deps.recipes) do
		self:_validate(id, recipe, deps.itemExists)
	end
	return self
end

function CraftingEngine:_validate(id, r, itemExists)
	assert(type(r.displayName) == "string", ("recipe %s needs a displayName"):format(id))
	assert(type(r.inputs) == "table" and next(r.inputs) ~= nil, ("recipe %s needs inputs"):format(id))
	assert(type(r.outputs) == "table" and #r.outputs > 0, ("recipe %s needs outputs"):format(id))
	assert(self._stations[r.station] ~= nil, ("recipe %s: unknown station %s"):format(id, tostring(r.station)))
	assert(type(r.craftTime) == "number" and r.craftTime >= 0, ("recipe %s needs craftTime"):format(id))
	for itemId, qty in pairs(r.inputs) do
		assert(type(qty) == "number" and qty >= 1 and qty == math.floor(qty), ("recipe %s: bad input qty for %s"):format(id, itemId))
		if itemExists then
			assert(itemExists(itemId), ("recipe %s: unknown input item %s"):format(id, itemId))
		end
	end
	for _, out in ipairs(r.outputs) do
		assert(type(out.item) == "string", ("recipe %s: output needs an item"):format(id))
		assert(type(out.qty) == "number" and out.qty >= 1 and out.qty == math.floor(out.qty), ("recipe %s: bad output qty"):format(id))
		if itemExists then
			assert(itemExists(out.item), ("recipe %s: unknown output item %s"):format(id, out.item))
		end
	end
end

function CraftingEngine:Get(recipeId)
	return self._recipes[recipeId]
end

-- Staff recipe locks (GDD §11.3 narrative restrictions). faction nil locks it for everyone.
function CraftingEngine:SetLocked(recipeId, faction, locked)
	if not self._recipes[recipeId] then
		return false, "UnknownRecipe"
	end
	local set = self._locks[recipeId] or {}
	set[faction or ANY] = locked == true or nil
	self._locks[recipeId] = next(set) and set or nil
	return true
end

function CraftingEngine:IsLocked(recipeId, faction)
	local set = self._locks[recipeId]
	return set ~= nil and (set[ANY] == true or (faction ~= nil and set[faction] == true))
end

--[[
	ctx:
		faction        gatherer's WorldConfig faction key
		rank           overall faction rank (number)
		hasPermission  function(flag) -> boolean
		countOf        function(itemId) -> number (carried quantity)
		station        { type = <Stations key>, operational = boolean, faction = key? }
]]
function CraftingEngine:Check(recipeId, ctx)
	local r = self._recipes[recipeId]
	if not r then
		return false, "UnknownRecipe"
	end
	if self:IsLocked(recipeId, ctx.faction) then
		return false, "RecipeLocked"
	end
	if r.factions then
		local ok = false
		for _, f in ipairs(r.factions) do
			if f == ctx.faction then
				ok = true
			end
		end
		if not ok then
			return false, "FactionNotAllowed"
		end
	end
	local station = ctx.station
	if not station or station.type ~= r.station then
		return false, "WrongStation"
	end
	if station.operational == false then
		return false, "StationUnavailable"
	end
	if station.faction ~= nil and station.faction ~= ctx.faction then
		return false, "StationNotYours"
	end
	if r.minRank and (type(ctx.rank) ~= "number" or ctx.rank < r.minRank) then
		return false, "RankTooLow"
	end
	if r.permission and not (ctx.hasPermission and ctx.hasPermission(r.permission)) then
		return false, "MissingPermission"
	end
	for itemId, qty in pairs(r.inputs) do
		if ctx.countOf(itemId) < qty then
			return false, "MissingMaterials"
		end
	end
	return true
end

-- The exact inventory changes a craft makes: { consume = { [itemId] = qty }, grant = { {item, qty} } }.
function CraftingEngine:Plan(recipeId)
	local r = self._recipes[recipeId]
	if not r then
		return nil
	end
	local consume = {}
	for itemId, qty in pairs(r.inputs) do
		consume[itemId] = qty
	end
	local grant = {}
	for i, out in ipairs(r.outputs) do
		grant[i] = { item = out.item, qty = out.qty }
	end
	return { consume = consume, grant = grant }
end

--[[
	Applies a plan through an inventory adapter, all or nothing:
		inv.count(itemId) -> number
		inv.consume(itemId, qty) -> ok, err
		inv.grant(itemId, qty) -> ok, err
		inv.ungrant(itemId, qty)   undo a grant (used only on failure)
		inv.unconsume(itemId, qty) undo a consume (used only on failure)
	Must run without yielding. Returns ok, err.
]]
function CraftingEngine.Apply(plan, inv)
	for itemId, qty in pairs(plan.consume) do
		if inv.count(itemId) < qty then
			return false, "MissingMaterials"
		end
	end
	local consumed, granted = {}, {}
	local function rollback()
		for i = #granted, 1, -1 do
			inv.ungrant(granted[i].item, granted[i].qty)
		end
		for i = #consumed, 1, -1 do
			inv.unconsume(consumed[i].item, consumed[i].qty)
		end
	end
	for itemId, qty in pairs(plan.consume) do
		local ok, err = inv.consume(itemId, qty)
		if not ok then
			rollback()
			return false, err or "ConsumeFailed"
		end
		table.insert(consumed, { item = itemId, qty = qty })
	end
	for _, g in ipairs(plan.grant) do
		local ok, err = inv.grant(g.item, g.qty)
		if not ok then
			rollback()
			return false, err or "GrantFailed"
		end
		table.insert(granted, g)
	end
	return true
end

-- Recipes this crafter could see in a station's UI, with the reason each is blocked.
function CraftingEngine:ListFor(stationType, ctx)
	local out = {}
	for id, r in pairs(self._recipes) do
		if r.station == stationType then
			local ok, err = self:Check(id, ctx)
			table.insert(out, { id = id, displayName = r.displayName, craftTime = r.craftTime, inputs = r.inputs, outputs = r.outputs, ok = ok, reason = err })
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function CraftingEngine:SerializeLocks()
	return self._locks
end

function CraftingEngine:LoadLocks(data)
	self._locks = {}
	for recipeId, set in pairs(data or {}) do
		if self._recipes[recipeId] then
			self._locks[recipeId] = set
		end
	end
end

return CraftingEngine
