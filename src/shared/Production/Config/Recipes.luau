--[[
	Recipes (GDD §11).

	Fields:
		displayName  shown in the crafting UI
		inputs       { [itemId] = quantity }
		outputs      list of { item = itemId, qty }
		station      Stations key required
		craftTime    seconds of uninterrupted channel
		factions     optional list of WorldConfig faction keys allowed to craft it
		minRank      optional overall faction rank required (read only; never changed here)
		permission   optional faction permission flag (see CraftingService)

	Crafting a weapon gives the weapon ITEM only. It never grants the weapon kit:
	whether the character may use the moveset is decided by the kits the Loreteam
	assigned, which CombatService checks on equip (GDD §11.2, §16.5).

	These use the placeholder items from ItemDefinitions. Replace with real content.
]]

return {
	StandardSword = {
		displayName = "Standard Sword",
		inputs = { ["Material.Common"] = 6, ["Material.Industrial"] = 2 },
		outputs = { { item = "Weapon.SwordStandard", qty = 1 } },
		station = "Forge",
		craftTime = 8,
	},

	RecurveBow = {
		displayName = "Recurve Bow",
		inputs = { ["Material.Natural"] = 6, ["Material.Common"] = 1 },
		outputs = { { item = "Weapon.BowRecurve", qty = 1 } },
		station = "Fletchery",
		craftTime = 8,
	},

	MedicalSupplies = {
		displayName = "Medical Supplies",
		inputs = { ["Material.Natural"] = 2, ["Material.Rare"] = 1 },
		outputs = { { item = "Consumable.Medkit", qty = 2 } },
		station = "FieldLab",
		craftTime = 5,
	},
}
