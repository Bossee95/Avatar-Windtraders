--[[
	InventoryStore

	Authoritative, in-memory record of every item instance and which container holds it
	(GDD §16.2). Pure Lua with no Roblox APIs, so it can be unit-tested outside Studio.

	Containers are identified by string keys:
		char:<characterId>     items the character is carrying
		storage:<characterId>  separately stored items (GDD §9.3)
		satchel:<satchelId>    a death satchel's contents

	Account-wide weapon skins live in SkinStore and never appear here.

	Atomicity: ApplyTransfers checks every transfer before changing anything, and then
	applies all of them without yielding. On a Roblox server, where only one Lua thread
	runs at a time, nothing can observe or change the store halfway through, so a trade
	either moves every item or none of them.

	Item instance: { uid, itemId, quantity, container }

	Category caps: `categoryLimits` (e.g. { Weapon = 1 }) limits how many items of a
	category one character may carry. Only character containers (char:*) are capped;
	satchels are not. Grants and transfers that would go over a cap are refused with
	"<Category>Limit" (e.g. "WeaponLimit"). A swap stays legal: items leaving in the
	same batch are counted before items arriving.
]]

local InventoryStore = {}
InventoryStore.__index = InventoryStore

InventoryStore.Container = {}
function InventoryStore.Container.Character(characterId)
	return "char:" .. tostring(characterId)
end
function InventoryStore.Container.Storage(characterId)
	return "storage:" .. tostring(characterId)
end
function InventoryStore.Container.Satchel(satchelId)
	return "satchel:" .. tostring(satchelId)
end

local function isPositiveInteger(n)
	return type(n) == "number" and n >= 1 and n == math.floor(n)
end

--[[
	deps:
		registry        ItemRegistry
		newId           function(): string   unique id generator (HttpService:GenerateGUID on Roblox)
		categoryLimits  { [category]: number }?  per-character caps, e.g. { Weapon = 1 }
]]
function InventoryStore.new(deps)
	assert(deps and deps.registry, "InventoryStore needs a registry")
	local counter = 0
	local self = setmetatable({
		_registry = deps.registry,
		_newId = deps.newId or function()
			counter = counter + 1
			return "item-" .. counter
		end,
		_items = {}, -- uid -> item
		_containers = {}, -- key -> { [uid] = true }
		_listeners = {},
		_limits = deps.categoryLimits or {},
	}, InventoryStore)
	return self
end

local function isCapped(key)
	return type(key) == "string" and key:sub(1, 5) == "char:"
end

-- Number of items of a category in a container (stack quantities included).
function InventoryStore:CountCategory(key, category)
	local total = 0
	for uid in pairs(self._containers[key] or {}) do
		local item = self._items[uid]
		local def = self._registry:Get(item.itemId)
		if def and def.category == category then
			total = total + item.quantity
		end
	end
	return total
end

-- deltas: { [containerKey] = { [category] = change } }. Returns false, reason if any
-- capped container would end up over its limit.
function InventoryStore:_checkLimits(deltas)
	for key, byCategory in pairs(deltas) do
		if isCapped(key) then
			for category, change in pairs(byCategory) do
				local limit = self._limits[category]
				if limit and change > 0 and self:CountCategory(key, category) + change > limit then
					return false, category .. "Limit"
				end
			end
		end
	end
	return true
end

-- Whether quantity of itemId may be added to the container.
function InventoryStore:CanGrant(key, itemId, quantity)
	local def = self._registry:Get(itemId)
	if not def then
		return false, "UnknownItem"
	end
	return self:_checkLimits({ [key] = { [def.category] = quantity or 1 } })
end

-- Registers fn(changedKeys: { [containerKey] = true }) to run after every mutation.
-- Use it to mark containers dirty for saving and to push inventory updates to clients.
function InventoryStore:OnChanged(fn)
	table.insert(self._listeners, fn)
	return function()
		for i, f in ipairs(self._listeners) do
			if f == fn then
				table.remove(self._listeners, i)
				return
			end
		end
	end
end

function InventoryStore:_emit(changed)
	for _, fn in ipairs(self._listeners) do
		fn(changed)
	end
end

function InventoryStore:_set(key)
	local set = self._containers[key]
	if not set then
		set = {}
		self._containers[key] = set
	end
	return set
end

function InventoryStore:_insert(key, itemId, quantity, uid)
	local item = { uid = uid or self._newId(), itemId = itemId, quantity = quantity, container = key }
	self._items[item.uid] = item
	self:_set(key)[item.uid] = true
	return item
end

function InventoryStore:_delete(item)
	self._items[item.uid] = nil
	local set = self._containers[item.container]
	if set then
		set[item.uid] = nil
	end
end

-- Adds quantity of itemId to the container, filling existing stacks first.
-- Returns the list of item instances that received quantity.
function InventoryStore:_add(key, itemId, quantity)
	local def = self._registry:Get(itemId)
	local touched = {}
	local remaining = quantity
	if def.stackable then
		for uid in pairs(self:_set(key)) do
			local item = self._items[uid]
			if remaining <= 0 then
				break
			end
			if item.itemId == itemId and item.quantity < def.maxStack then
				local add = math.min(def.maxStack - item.quantity, remaining)
				item.quantity = item.quantity + add
				remaining = remaining - add
				table.insert(touched, item)
			end
		end
	end
	while remaining > 0 do
		local amount = def.stackable and math.min(def.maxStack, remaining) or 1
		table.insert(touched, self:_insert(key, itemId, amount))
		remaining = remaining - amount
	end
	return touched
end

-- Gives a character (or any container) new items. Returns the item instances, or
-- nil and a reason (e.g. "WeaponLimit") if a category cap would be exceeded.
function InventoryStore:Grant(key, itemId, quantity)
	quantity = quantity or 1
	assert(self._registry:Exists(itemId), ("unknown item %s"):format(tostring(itemId)))
	assert(isPositiveInteger(quantity), "quantity must be a positive integer")
	local allowed, reason = self:CanGrant(key, itemId, quantity)
	if not allowed then
		return nil, reason
	end
	local touched = self:_add(key, itemId, quantity)
	self:_emit({ [key] = true })
	return touched
end

function InventoryStore:GetItem(uid)
	return self._items[uid]
end

-- Returns a snapshot list of the container's items, sorted by itemId then uid.
function InventoryStore:GetContainer(key)
	local list = {}
	for uid in pairs(self._containers[key] or {}) do
		local item = self._items[uid]
		table.insert(list, { uid = item.uid, itemId = item.itemId, quantity = item.quantity, container = item.container })
	end
	table.sort(list, function(a, b)
		if a.itemId == b.itemId then
			return a.uid < b.uid
		end
		return a.itemId < b.itemId
	end)
	return list
end

function InventoryStore:CountOf(key, itemId)
	local total = 0
	for uid in pairs(self._containers[key] or {}) do
		local item = self._items[uid]
		if item.itemId == itemId then
			total = total + item.quantity
		end
	end
	return total
end

-- Removes quantity from one item instance (whole instance if quantity is nil).
function InventoryStore:Remove(uid, quantity)
	local item = self._items[uid]
	if not item then
		return false, "ItemNotFound"
	end
	quantity = quantity or item.quantity
	if not isPositiveInteger(quantity) or quantity > item.quantity then
		return false, "InvalidQuantity"
	end
	local key = item.container
	if quantity == item.quantity then
		self:_delete(item)
	else
		item.quantity = item.quantity - quantity
	end
	self:_emit({ [key] = true })
	return true
end

-- Deletes every item in a container. Returns the removed snapshot.
function InventoryStore:ClearContainer(key)
	local removed = self:GetContainer(key)
	for _, snap in ipairs(removed) do
		self:_delete(self._items[snap.uid])
	end
	self._containers[key] = nil
	if #removed > 0 then
		self:_emit({ [key] = true })
	end
	return removed
end

--[[
	Checks a batch of transfers without applying it.
	transfers: array of { uid, quantity, from, to }
		from is required: the item must currently be in that container (ownership check).
	Returns true, or false and a reason string.
]]
function InventoryStore:ValidateTransfers(transfers)
	local claimed = {}
	local deltas = {}
	for _, t in ipairs(transfers) do
		local item = self._items[t.uid]
		if not item then
			return false, "ItemNotFound"
		end
		if item.container ~= t.from then
			return false, "NotOwner"
		end
		if type(t.to) ~= "string" or t.to == "" or t.to == t.from then
			return false, "InvalidDestination"
		end
		if not isPositiveInteger(t.quantity) then
			return false, "InvalidQuantity"
		end
		claimed[t.uid] = (claimed[t.uid] or 0) + t.quantity
		if claimed[t.uid] > item.quantity then
			return false, "InsufficientQuantity"
		end
		local def = self._registry:Get(item.itemId)
		if def and self._limits[def.category] then
			deltas[t.from] = deltas[t.from] or {}
			deltas[t.to] = deltas[t.to] or {}
			deltas[t.from][def.category] = (deltas[t.from][def.category] or 0) - t.quantity
			deltas[t.to][def.category] = (deltas[t.to][def.category] or 0) + t.quantity
		end
	end
	return self:_checkLimits(deltas)
end

--[[
	Atomically applies a batch of transfers: all succeed or nothing changes.
	Returns true and a list of { itemId, quantity, from, to } moved, or false and a reason.
]]
function InventoryStore:ApplyTransfers(transfers)
	local ok, reason = self:ValidateTransfers(transfers)
	if not ok then
		return false, reason
	end

	-- Nothing below can fail or yield.
	local changed = {}
	local moved = {}
	for _, t in ipairs(transfers) do
		local item = self._items[t.uid]
		local def = self._registry:Get(item.itemId)
		changed[t.from] = true
		changed[t.to] = true
		table.insert(moved, { itemId = item.itemId, quantity = t.quantity, from = t.from, to = t.to })
		if t.quantity == item.quantity then
			self:_delete(item)
			if def.stackable then
				self:_add(t.to, item.itemId, t.quantity)
			else
				-- Keep the uid so a unique item (e.g. a crafted weapon) can be traced across owners.
				self:_insert(t.to, item.itemId, t.quantity, item.uid)
			end
		else
			item.quantity = item.quantity - t.quantity
			self:_add(t.to, item.itemId, t.quantity)
		end
	end
	self:_emit(changed)
	return true, moved
end

-- Serialises a container for saving: array of { uid, itemId, quantity }.
function InventoryStore:Serialize(key)
	local out = {}
	for _, item in ipairs(self:GetContainer(key)) do
		table.insert(out, { uid = item.uid, itemId = item.itemId, quantity = item.quantity })
	end
	return out
end

-- Replaces a container's contents with saved data. Unknown item ids are skipped
-- (and returned) so a removed item definition cannot break loading.
function InventoryStore:Load(key, data)
	for uid in pairs(self._containers[key] or {}) do
		self._items[uid] = nil
	end
	self._containers[key] = {}
	local skipped = {}
	for _, entry in ipairs(data or {}) do
		if self._registry:Exists(entry.itemId) and isPositiveInteger(entry.quantity) and not self._items[entry.uid] then
			self:_insert(key, entry.itemId, entry.quantity, entry.uid)
		else
			table.insert(skipped, entry)
		end
	end
	return skipped
end

-- Drops a container from memory without emitting a change (e.g. after saving on leave).
function InventoryStore:Unload(key)
	for uid in pairs(self._containers[key] or {}) do
		self._items[uid] = nil
	end
	self._containers[key] = nil
end

return InventoryStore
