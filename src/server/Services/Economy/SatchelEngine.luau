--[[
	SatchelEngine

	Death satchels (GDD §9.2, §16.3 step 4). Pure Lua; Roblox parts, prompts and the
	PD state are handled by DeathSatchelService.

	Rules:
		- Every tradeable item the dead character carried goes into the satchel.
		- Untradeable items are not placed in the satchel. They are destroyed with the
		  character, because character possessions are lost on Permanent Death.
		- Weapon skins are account-wide (SkinStore) and are never touched.
		- A satchel belongs to the PD event the death happened in. It can be looted only
		  while that same event is active, and it is removed when the event ends.
		- A looter cannot take a weapon while already carrying one ("WeaponLimit").
		- Each loot is atomic: two players grabbing the same item at once cannot both
		  get it (the second claim fails with "ItemGone").

	Satchel: { id, pdEventId, ownerUserId, ownerCharacterId, ownerFaction, location,
	           createdAt, container, openedBy }
]]

local SatchelEngine = {}
SatchelEngine.__index = SatchelEngine

local function noop() end

--[[
	deps:
		inventory       InventoryStore
		registry        ItemRegistry
		log             TradeLog
		config          EconomyConfig
		now             function(): number
		newId           function(): string            optional
		isLootOpen      function(pdEventId): boolean  that event is the active PD (pause rules applied by caller)
		getUserId       function(player): number
		getCharacterId  function(player): string?     living character only
		getFaction      function(player): string?     optional
		getDistance     function(player, location): number?  optional
		onCreated, onChanged, onRemoved   function(satchel)  optional
]]
function SatchelEngine.new(deps)
	for _, key in ipairs({ "inventory", "registry", "log", "config", "now", "isLootOpen", "getUserId", "getCharacterId" }) do
		assert(deps[key] ~= nil, "SatchelEngine missing dependency " .. key)
	end
	local counter = 0
	return setmetatable({
		_d = deps,
		_cfg = deps.config,
		_newId = deps.newId or function()
			counter = counter + 1
			return "satchel-" .. counter
		end,
		_onCreated = deps.onCreated or noop,
		_onChanged = deps.onChanged or noop,
		_onRemoved = deps.onRemoved or noop,
		_satchels = {},
	}, SatchelEngine)
end

function SatchelEngine:Get(satchelId)
	return self._satchels[satchelId]
end

function SatchelEngine:List(pdEventId)
	local out = {}
	for _, satchel in pairs(self._satchels) do
		if pdEventId == nil or satchel.pdEventId == pdEventId then
			table.insert(out, satchel)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function SatchelEngine:Contents(satchelId)
	local satchel = self._satchels[satchelId]
	if not satchel then
		return {}
	end
	return self._d.inventory:GetContainer(satchel.container)
end

local function snapshotItems(list)
	local out = {}
	for _, item in ipairs(list) do
		table.insert(out, { uid = item.uid, itemId = item.itemId, quantity = item.quantity })
	end
	return out
end

--[[
	Called from the Permadeath transfer hook, after the character is marked dead.
	death: { userId, characterId, pdEventId, faction?, location? }

	Must not yield and is all-or-nothing: everything is computed and validated before
	the inventory changes, and the changes themselves cannot fail.

	Returns a result table:
		{ satchel = satchel?, moved = { items }, destroyed = { items } }
	satchel is nil when the character carried nothing tradeable.
]]
function SatchelEngine:CreateFromDeath(death)
	assert(type(death) == "table" and death.characterId and death.pdEventId, "CreateFromDeath needs characterId and pdEventId")
	local inventory, registry = self._d.inventory, self._d.registry
	local Container = inventory.Container

	local sources = { Container.Character(death.characterId) }
	if self._cfg.StorageItemsDropOnDeath then
		table.insert(sources, Container.Storage(death.characterId))
	end

	local satchelId = self._newId()
	local satchelKey = Container.Satchel(satchelId)
	local transfers, moved, destroyed = {}, {}, {}
	for _, source in ipairs(sources) do
		for _, item in ipairs(inventory:GetContainer(source)) do
			if registry:IsTradeable(item.itemId) then
				table.insert(transfers, { uid = item.uid, quantity = item.quantity, from = source, to = satchelKey })
				table.insert(moved, { uid = item.uid, itemId = item.itemId, quantity = item.quantity })
			else
				table.insert(destroyed, { uid = item.uid, itemId = item.itemId, quantity = item.quantity })
			end
		end
	end

	local satchel = nil
	if #transfers > 0 then
		local ok, reason = inventory:ApplyTransfers(transfers)
		if not ok then
			-- Cannot happen with a fresh snapshot; raising makes the core roll the death back.
			error("satchel transfer failed: " .. tostring(reason))
		end
		satchel = {
			id = satchelId,
			pdEventId = death.pdEventId,
			ownerUserId = death.userId,
			ownerCharacterId = death.characterId,
			ownerFaction = death.faction,
			location = death.location,
			createdAt = self._d.now(),
			container = satchelKey,
		}
		self._satchels[satchelId] = satchel
	end
	-- What is left (untradeable items) is lost with the character.
	inventory:ClearContainer(sources[1])

	self._d.log:Record({
		kind = "SatchelCreated",
		status = "Completed",
		satchelId = satchel and satchel.id or nil,
		pdEventId = death.pdEventId,
		players = { death.userId },
		characterId = death.characterId,
		items = moved,
		destroyed = destroyed,
	})
	if satchel then
		self._onCreated(satchel)
	end
	return { satchel = satchel, moved = moved, destroyed = destroyed }
end

--[[
	Reverses CreateFromDeath when the death is rolled back (another transfer hook
	failed). result is the table CreateFromDeath returned.
]]
function SatchelEngine:UndoDeath(death, result)
	local inventory = self._d.inventory
	local charKey = inventory.Container.Character(death.characterId)
	if result.satchel then
		local transfers = {}
		for _, item in ipairs(inventory:GetContainer(result.satchel.container)) do
			table.insert(transfers, { uid = item.uid, quantity = item.quantity, from = item.container, to = charKey })
		end
		inventory:ApplyTransfers(transfers)
		self:_remove(result.satchel)
	end
	if #result.destroyed > 0 then
		local restored = inventory:Serialize(charKey)
		for _, item in ipairs(result.destroyed) do
			table.insert(restored, { uid = item.uid, itemId = item.itemId, quantity = item.quantity })
		end
		inventory:Load(charKey, restored)
	end
	self._d.log:Record({
		kind = "SatchelCreated",
		status = "RolledBack",
		satchelId = result.satchel and result.satchel.id or nil,
		pdEventId = death.pdEventId,
		players = { death.userId },
		characterId = death.characterId,
		items = result.moved,
	})
end

function SatchelEngine:_remove(satchel)
	if self._satchels[satchel.id] then
		self._satchels[satchel.id] = nil
		self._d.inventory:ClearContainer(satchel.container)
		self._onRemoved(satchel)
	end
end

function SatchelEngine:CanLoot(player, satchelId)
	local satchel = self._satchels[satchelId]
	if not satchel then
		return false, "NoSuchSatchel"
	end
	local d, cfg = self._d, self._cfg
	if not d.isLootOpen(satchel.pdEventId) then
		return false, "PDNotActive"
	end
	local characterId = d.getCharacterId(player)
	if not characterId then
		return false, "NoLivingCharacter"
	end
	if not cfg.SatchelOwnerCanLoot and d.getUserId(player) == satchel.ownerUserId then
		return false, "OwnSatchel"
	end
	local policy = cfg.SatchelLootableBy or "Anyone"
	if policy ~= "Anyone" and d.getFaction then
		local faction = d.getFaction(player)
		if policy == "SameFaction" and faction ~= satchel.ownerFaction then
			return false, "WrongFaction"
		elseif policy == "OtherFaction" and faction == satchel.ownerFaction then
			return false, "WrongFaction"
		end
	end
	if cfg.SatchelLootRange and d.getDistance and satchel.location ~= nil then
		local dist = d.getDistance(player, satchel.location)
		if dist == nil or dist > cfg.SatchelLootRange then
			return false, "TooFar"
		end
	end
	if not cfg.SatchelConcurrentLooting and satchel.openedBy ~= nil and satchel.openedBy ~= player then
		return false, "InUse"
	end
	return true, characterId
end

-- Opens the satchel UI. With concurrent looting off, the first opener holds it.
function SatchelEngine:Open(player, satchelId)
	local ok, reason = self:CanLoot(player, satchelId)
	if not ok then
		return false, reason
	end
	local satchel = self._satchels[satchelId]
	if not self._cfg.SatchelConcurrentLooting then
		satchel.openedBy = player
	end
	return true, self:Contents(satchelId)
end

function SatchelEngine:Close(player, satchelId)
	local satchel = self._satchels[satchelId]
	if satchel and satchel.openedBy == player then
		satchel.openedBy = nil
	end
end

-- Releases any satchel a player was holding (leaving, dying).
function SatchelEngine:ReleasePlayer(player)
	for _, satchel in pairs(self._satchels) do
		if satchel.openedBy == player then
			satchel.openedBy = nil
		end
	end
end

--[[
	Takes items out of a satchel into the looter's carried inventory.
	picks: array of { uid, quantity? } (quantity defaults to the whole stack),
	       or nil to take everything.
]]
function SatchelEngine:Loot(player, satchelId, picks)
	local ok, characterIdOrReason = self:CanLoot(player, satchelId)
	if not ok then
		return false, characterIdOrReason
	end
	local satchel = self._satchels[satchelId]
	if not self._cfg.SatchelConcurrentLooting and satchel.openedBy ~= player then
		return false, "NotOpened"
	end
	local inventory = self._d.inventory
	local to = inventory.Container.Character(characterIdOrReason)

	local transfers, taken = {}, {}
	if picks == nil then
		for _, item in ipairs(inventory:GetContainer(satchel.container)) do
			table.insert(transfers, { uid = item.uid, quantity = item.quantity, from = satchel.container, to = to })
		end
	else
		if type(picks) ~= "table" or #picks == 0 then
			return false, "NothingSelected"
		end
		for _, pick in ipairs(picks) do
			local item = inventory:GetItem(pick.uid)
			if not item or item.container ~= satchel.container then
				return false, "ItemGone"
			end
			table.insert(transfers, { uid = pick.uid, quantity = pick.quantity or item.quantity, from = satchel.container, to = to })
		end
	end
	if #transfers == 0 then
		return false, "Empty"
	end
	for _, t in ipairs(transfers) do
		local item = inventory:GetItem(t.uid)
		table.insert(taken, { uid = t.uid, itemId = item.itemId, quantity = t.quantity })
	end

	local applied, reason = inventory:ApplyTransfers(transfers)
	if not applied then
		return false, reason == "NotOwner" and "ItemGone" or reason
	end

	self._d.log:Record({
		kind = "SatchelLoot",
		status = "Completed",
		satchelId = satchel.id,
		pdEventId = satchel.pdEventId,
		players = { self._d.getUserId(player), satchel.ownerUserId },
		looterCharacterId = characterIdOrReason,
		ownerCharacterId = satchel.ownerCharacterId,
		items = taken,
	})

	if #inventory:GetContainer(satchel.container) == 0 then
		self:_remove(satchel)
	else
		self._onChanged(satchel)
	end
	return true, taken
end

-- Removes every satchel from the given PD event, with its unclaimed contents.
function SatchelEngine:ClearEvent(pdEventId, reason)
	local count = 0
	for _, satchel in ipairs(self:List(pdEventId)) do
		local left = snapshotItems(self._d.inventory:GetContainer(satchel.container))
		self:_remove(satchel)
		self._d.log:Record({
			kind = "SatchelCleared",
			status = "Completed",
			reason = reason or "PDEnded",
			satchelId = satchel.id,
			pdEventId = satchel.pdEventId,
			players = { satchel.ownerUserId },
			items = left,
		})
		count = count + 1
	end
	return count
end

-- Removes satchels that do not belong to the given (current) event, or all if nil.
-- Safety net in case an EventEnded signal was missed.
function SatchelEngine:ClearStale(activeEventId)
	local stale = {}
	for _, satchel in pairs(self._satchels) do
		if satchel.pdEventId ~= activeEventId then
			stale[satchel.pdEventId] = true
		end
	end
	local count = 0
	for eventId in pairs(stale) do
		count = count + self:ClearEvent(eventId, "Stale")
	end
	return count
end

return SatchelEngine
