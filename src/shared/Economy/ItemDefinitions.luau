--[[
	ItemDefinitions

	Every item in the game (GDD §8.1). Add new items here. Fields are documented in
	ItemRegistry. Items are tradeable by default; set `untradeable = true` only for a
	specific item with a defined reason (GDD §8.2).

	These are placeholder entries so the systems can be exercised. Replace their names
	and descriptions with the real content. Weapon items name the combat variation they
	equip (Shared.Combat.Config.Variations).
]]

return {
	-- Weapons
	{ id = "Weapon.SwordStandard", name = "Standard Sword", description = "A standard sword.", category = "Weapon", variationId = "Sword_Standard" },
	{ id = "Weapon.BowRecurve", name = "Recurve Bow", description = "A recurve bow.", category = "Weapon", variationId = "Bow_Recurve" },

	-- Materials and resources (GDD §10.2)
	{ id = "Material.Common", name = "Common Material", description = "Used for basic crafting and construction.", category = "Material", stackable = true, maxStack = 200 },
	{ id = "Material.Industrial", name = "Industrial Material", description = "Used for machinery and manufacturing.", category = "Material", stackable = true, maxStack = 200 },
	{ id = "Material.Natural", name = "Natural Material", description = "Gathered from the environment.", category = "Material", stackable = true, maxStack = 200 },
	{ id = "Material.Rare", name = "Rare Material", description = "Scarce. Used for specialised equipment.", category = "Material", stackable = true, maxStack = 50 },

	-- Consumables
	{ id = "Consumable.Medkit", name = "Medical Supplies", description = "Treats injuries.", category = "Consumable", stackable = true, maxStack = 10 },

	-- Example of an Untradeable item: bound to the character that earned it.
	{ id = "EventReward.Commendation", name = "Commendation", description = "Awarded for a recognised achievement. Cannot be traded.", category = "EventReward", untradeable = true },
}
