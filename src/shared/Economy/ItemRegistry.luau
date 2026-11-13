--[[
	ItemRegistry

	Item definitions (GDD §8.1, §8.2). Every item has a name, description, category and
	tradeability. All items are tradeable unless they are tagged Untradeable.

	Weapon skins are NOT items: they are account-wide cosmetics kept in SkinStore, can
	never be traded and are never placed in a death satchel (GDD §7.3, §16.6). Defining an
	item with the WeaponSkin category is rejected so a skin cannot leak into the item
	economy by mistake.

	Definition fields:
		id           string   unique id, e.g. "Material.Unobtanium"
		name         string
		description  string
		category     one of ItemRegistry.Categories
		untradeable  boolean? true tags the item Untradeable
		stackable    boolean? stack instances by quantity (default false)
		maxStack     number?  cap for stackable items (default 999)
		variationId  string?  Weapon items only: the combat weapon variation this item
		                      lets the character equip (Shared.Combat.Config.Variations key)
]]

local ItemRegistry = {}
ItemRegistry.__index = ItemRegistry

ItemRegistry.Categories = {
	Weapon = "Weapon",
	Material = "Material",
	Consumable = "Consumable",
	Equipment = "Equipment",
	Resource = "Resource",
	Special = "Special",
	EventReward = "EventReward",
	Other = "Other",
}

local DEFAULT_MAX_STACK = 999

local function validate(def)
	assert(type(def) == "table", "item definition must be a table")
	assert(type(def.id) == "string" and def.id ~= "", "item definition needs an id")
	assert(type(def.name) == "string", ("item %s needs a name"):format(def.id))
	assert(type(def.description) == "string", ("item %s needs a description"):format(def.id))
	if def.category == "WeaponSkin" then
		error(("item %s: weapon skins belong in SkinStore, not the item registry"):format(def.id))
	end
	assert(ItemRegistry.Categories[def.category] ~= nil, ("item %s has unknown category %s"):format(def.id, tostring(def.category)))
	if def.variationId ~= nil then
		assert(def.category == "Weapon", ("item %s: only weapons can have a variationId"):format(def.id))
		assert(type(def.variationId) == "string", ("item %s: variationId must be a string"):format(def.id))
	end
end

function ItemRegistry.new(definitions)
	local self = setmetatable({ _defs = {} }, ItemRegistry)
	for _, def in ipairs(definitions or {}) do
		self:Register(def)
	end
	return self
end

function ItemRegistry:Register(def)
	validate(def)
	assert(self._defs[def.id] == nil, ("duplicate item id %s"):format(def.id))
	self._defs[def.id] = {
		id = def.id,
		name = def.name,
		description = def.description,
		category = def.category,
		untradeable = def.untradeable == true,
		stackable = def.stackable == true,
		maxStack = def.stackable and (def.maxStack or DEFAULT_MAX_STACK) or 1,
		variationId = def.variationId,
	}
end

function ItemRegistry:Get(itemId)
	return self._defs[itemId]
end

function ItemRegistry:Exists(itemId)
	return self._defs[itemId] ~= nil
end

function ItemRegistry:IsTradeable(itemId)
	local def = self._defs[itemId]
	return def ~= nil and not def.untradeable
end

function ItemRegistry:All()
	local list = {}
	for _, def in pairs(self._defs) do
		table.insert(list, def)
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

return ItemRegistry
