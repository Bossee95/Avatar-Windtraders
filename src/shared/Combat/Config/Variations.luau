--!strict
--[[
	Weapon variations (GDD §5.5, §6.4, §11.2).

	A variation is a specific weapon (standard issue, crafted, or specially
	acquired). It belongs to one weapon type, so it inherits that type's M1
	combo and the kit's Z/X/C. What a variation changes is its look and its
	R Critical attack.

	Owning a variation never grants the kit for its weapon type (§11.2). The
	server checks both: the character must own the variation AND hold a kit
	for its weapon type.

	Variations must not be objectively superior (§5.5). Keep differences in
	the Critical's trade-offs (damage vs range vs speed vs cooldown).
]]

export type Variation = {
	displayName: string,
	weaponType: string,
	critical: string,
}

local Variations: { [string]: Variation } = {
	Sword_Standard = { displayName = "Standard Sword", weaponType = "Sword", critical = "Crit_Sword_Execute" },
	Sword_Hooked = { displayName = "Hooked Sword", weaponType = "Sword", critical = "Crit_Sword_Cleave" },

	Spear_Standard = { displayName = "Standard Spear", weaponType = "Spear", critical = "Crit_Spear_Impale" },
	Spear_Barbed = { displayName = "Barbed Spear", weaponType = "Spear", critical = "Crit_Spear_Sweep" },

	Bow_Standard = { displayName = "Standard Bow", weaponType = "Bow", critical = "Crit_Bow_Heartseeker" },
	Bow_Recurve = { displayName = "Recurve Bow", weaponType = "Bow", critical = "Crit_Bow_Scatter" },

	Rifle_Standard = { displayName = "Standard Rifle", weaponType = "Rifle", critical = "Crit_Rifle_Overcharge" },
	Rifle_Marksman = { displayName = "Marksman Rifle", weaponType = "Rifle", critical = "Crit_Rifle_Pierce" },
}

return table.freeze(Variations)
