--[[
	NodeEngine

	Pure state for resource nodes (GDD §10.3): finite capacity, depletion, refills
	and staff overrides. No Roblox APIs, so it runs in the plain Lua spec runner.

	deps:
		nodeTypes  table from Production/Config/ResourceNodes
		random     optional function(min, max) -> integer (math.random by default)
		roll       optional function() -> number in [0, 1) (math.random by default)
]]

local NodeEngine = {}
NodeEngine.__index = NodeEngine

function NodeEngine.new(deps)
	assert(deps and deps.nodeTypes, "NodeEngine needs nodeTypes")
	for key, def in pairs(deps.nodeTypes) do
		NodeEngine.validateType(key, def)
	end
	return setmetatable({
		_types = deps.nodeTypes,
		_random = deps.random or math.random,
		_roll = deps.roll or math.random,
		_nodes = {},
	}, NodeEngine)
end

function NodeEngine.validateType(key, def)
	assert(type(def) == "table", ("node type %s must be a table"):format(tostring(key)))
	assert(type(def.capacity) == "number" and def.capacity >= 1, ("node type %s needs capacity >= 1"):format(key))
	assert(type(def.gatherTime) == "number" and def.gatherTime >= 0, ("node type %s needs gatherTime"):format(key))
	assert(type(def.yields) == "table" and #def.yields > 0, ("node type %s needs yields"):format(key))
	for _, y in ipairs(def.yields) do
		assert(type(y.item) == "string", ("node type %s: yield needs an item"):format(key))
		assert(type(y.min) == "number" and type(y.max) == "number" and y.min >= 0 and y.max >= y.min,
			("node type %s: yield %s needs 0 <= min <= max"):format(key, y.item))
	end
	local regen = def.regen or { mode = "None" }
	assert(regen.mode == "PerEvent" or regen.mode == "Timed" or regen.mode == "None",
		("node type %s: unknown regen mode %s"):format(key, tostring(regen.mode)))
	if regen.mode == "Timed" then
		assert(type(regen.every) == "number" and regen.every > 0, ("node type %s: Timed regen needs every > 0"):format(key))
	end
end

-- Registers a placed node. Saved state (from Load) wins over defaults.
function NodeEngine:AddNode(nodeId, nodeType, opts)
	local def = self._types[nodeType]
	if not def then
		return false, "UnknownNodeType"
	end
	if self._nodes[nodeId] and self._nodes[nodeId].nodeType then
		return false, "DuplicateNode"
	end
	opts = opts or {}
	local saved = self._nodes[nodeId]
	self._nodes[nodeId] = {
		id = nodeId,
		nodeType = nodeType,
		territory = opts.territory,
		capacity = (saved and saved.capacity) or def.capacity,
		remaining = (saved and saved.remaining) or def.capacity,
		enabled = (saved == nil) or saved.enabled ~= false,
		regenClock = 0,
	}
	if self._nodes[nodeId].remaining > self._nodes[nodeId].capacity then
		self._nodes[nodeId].remaining = self._nodes[nodeId].capacity
	end
	return true
end

function NodeEngine:RemoveNode(nodeId)
	self._nodes[nodeId] = nil
end

function NodeEngine:Get(nodeId)
	local node = self._nodes[nodeId]
	if not node or not node.nodeType then
		return nil
	end
	return node, self._types[node.nodeType]
end

--[[
	Checks whether a gatherer may gather this node now. ctx:
		faction        WorldConfig faction key of the gatherer
		hasItem        function(itemId) -> boolean (tool check)
		territoryOk    optional boolean from TerritoryService (nil = no territory rule yet)
]]
function NodeEngine:CanGather(nodeId, ctx)
	local node, def = self:Get(nodeId)
	if not node then
		return false, "UnknownNode"
	end
	if not node.enabled then
		return false, "NodeDisabled"
	end
	if node.remaining < 1 then
		return false, "NodeDepleted"
	end
	if def.factions then
		local allowed = false
		for _, f in ipairs(def.factions) do
			if f == ctx.faction then
				allowed = true
			end
		end
		if not allowed then
			return false, "FactionNotAllowed"
		end
	end
	if def.toolTag and not (ctx.hasItem and ctx.hasItem(def.toolTag)) then
		return false, "MissingTool"
	end
	if ctx.territoryOk == false then
		return false, "TerritoryDenied"
	end
	return true
end

-- Spends one unit of the node and returns the rolled yield as { [itemId] = qty }.
-- Call only after CanGather succeeded, without yielding in between.
function NodeEngine:Harvest(nodeId)
	local node, def = self:Get(nodeId)
	assert(node and node.remaining >= 1, "Harvest on a node that cannot be gathered")
	node.remaining = node.remaining - 1
	local items = {}
	for _, y in ipairs(def.yields) do
		if y.chance == nil or self._roll() < y.chance then
			local qty = (y.max > y.min) and self._random(y.min, y.max) or y.min
			if qty > 0 then
				items[y.item] = (items[y.item] or 0) + qty
			end
		end
	end
	return items
end

-- Undoes a Harvest whose items could not be granted.
function NodeEngine:Refund(nodeId)
	local node = self:Get(nodeId)
	if node and node.remaining < node.capacity then
		node.remaining = node.remaining + 1
	end
end

-- Refills every PerEvent node. Call when a PD starts. Returns the changed node ids.
function NodeEngine:RefillForEvent()
	local changed = {}
	for id, node in pairs(self._nodes) do
		local def = node.nodeType and self._types[node.nodeType]
		if def and def.regen and def.regen.mode == "PerEvent" and node.remaining < node.capacity then
			node.remaining = node.capacity
			table.insert(changed, id)
		end
	end
	return changed
end

-- Advances Timed regen by dt seconds. Call only while a PD is active.
function NodeEngine:Tick(dt)
	local changed = {}
	for id, node in pairs(self._nodes) do
		local def = node.nodeType and self._types[node.nodeType]
		if def and def.regen and def.regen.mode == "Timed" then
			if node.remaining >= node.capacity then
				node.regenClock = 0
			else
				node.regenClock = node.regenClock + dt
				local before = node.remaining
				while node.regenClock >= def.regen.every and node.remaining < node.capacity do
					node.regenClock = node.regenClock - def.regen.every
					node.remaining = node.remaining + 1
				end
				if node.remaining ~= before then
					table.insert(changed, id)
				end
			end
		end
	end
	return changed
end

-- Staff overrides (GDD §10.3: distribution changes between PDs). Return ok, err.
function NodeEngine:SetEnabled(nodeId, enabled)
	local node = self:Get(nodeId)
	if not node then
		return false, "UnknownNode"
	end
	node.enabled = enabled == true
	return true
end

function NodeEngine:SetCapacity(nodeId, capacity)
	local node = self:Get(nodeId)
	if not node then
		return false, "UnknownNode"
	end
	if type(capacity) ~= "number" or capacity < 0 or capacity ~= math.floor(capacity) then
		return false, "InvalidAmount"
	end
	node.capacity = capacity
	if node.remaining > capacity then
		node.remaining = capacity
	end
	return true
end

function NodeEngine:SetRemaining(nodeId, remaining)
	local node = self:Get(nodeId)
	if not node then
		return false, "UnknownNode"
	end
	if type(remaining) ~= "number" or remaining < 0 or remaining ~= math.floor(remaining) or remaining > node.capacity then
		return false, "InvalidAmount"
	end
	node.remaining = remaining
	return true
end

function NodeEngine:Snapshot(nodeId)
	local node = self:Get(nodeId)
	if not node then
		return nil
	end
	return { nodeId = node.id, nodeType = node.nodeType, remaining = node.remaining, capacity = node.capacity, enabled = node.enabled }
end

function NodeEngine:List()
	local out = {}
	for id in pairs(self._nodes) do
		local snap = self:Snapshot(id)
		if snap then
			table.insert(out, snap)
		end
	end
	table.sort(out, function(a, b)
		return a.nodeId < b.nodeId
	end)
	return out
end

-- Persistence: { [nodeId] = { remaining, capacity, enabled } }.
function NodeEngine:Serialize()
	local out = {}
	for id, node in pairs(self._nodes) do
		out[id] = { remaining = node.remaining, capacity = node.capacity, enabled = node.enabled }
	end
	return out
end

-- Load before or after AddNode; saved values win either way.
function NodeEngine:Load(data)
	for id, saved in pairs(data or {}) do
		local node = self._nodes[id]
		if node and node.nodeType then
			node.capacity = saved.capacity or node.capacity
			node.remaining = math.min(saved.remaining or node.remaining, node.capacity)
			node.enabled = saved.enabled ~= false
		else
			self._nodes[id] = { capacity = saved.capacity, remaining = saved.remaining, enabled = saved.enabled }
		end
	end
end

return NodeEngine
