--!strict
--[[
	Weapon kits (GDD §4.3, §5.1, §5.2, §5.4, §6.3).

	Kits[weaponType][level] is the moveset a character gets for that weapon
	type at that kit level. It provides the Z, X and C abilities. The M1 combo
	always comes from the weapon type and the R Critical from the equipped
	variation.

	The game never grants kits. The Loreteam grants a weapon type at a level
	through ProgressionService:GrantKit(actor, userId, characterId,
	weaponType, level), which is stored as character.kits[weaponType] =
	{ level = n }. Several weapon types can be held at the same rank, e.g. a
	rank 3 Warrior with Sword 3, Spear 3 and Bow 3; there are no per-weapon
	ranks (§4.3).

	A slot left nil is unavailable at that level. The placeholder progression
	unlocks Z at level 1, X at level 2 and C at level 3, but a level may
	define any slots. If a character's level is higher than any defined level
	for that weapon type, the highest defined level below it is used.

	To add a kit level: add an entry here and any new actions to
	Actions.luau. ConfigValidator checks the references on server start.
]]

export type Kit = {
	displayName: string,
	abilities: { Z: string?, X: string?, C: string? },
}

local Kits: { [string]: { [number]: Kit } } = {
	Sword = {
		[1] = { displayName = "Sword Kit I", abilities = { Z = "Sword_Lunge" } },
		[2] = { displayName = "Sword Kit II", abilities = { Z = "Sword_Lunge", X = "Sword_Sweep" } },
		[3] = {
			displayName = "Sword Kit III",
			abilities = { Z = "Sword_Lunge", X = "Sword_Sweep", C = "Sword_HeavySlash" },
		},
	},
	Spear = {
		[1] = { displayName = "Spear Kit I", abilities = { Z = "Spear_Thrust" } },
		[2] = { displayName = "Spear Kit II", abilities = { Z = "Spear_Thrust", X = "Spear_Spin" } },
		[3] = {
			displayName = "Spear Kit III",
			abilities = { Z = "Spear_Thrust", X = "Spear_Spin", C = "Spear_VaultStrike" },
		},
	},
	Bow = {
		[1] = { displayName = "Bow Kit I", abilities = { Z = "Bow_PowerShot" } },
		[2] = { displayName = "Bow Kit II", abilities = { Z = "Bow_PowerShot", X = "Bow_PinningShot" } },
		[3] = {
			displayName = "Bow Kit III",
			abilities = { Z = "Bow_PowerShot", X = "Bow_PinningShot", C = "Bow_Volley" },
		},
	},
	Rifle = {
		[1] = { displayName = "Rifle Kit I", abilities = { Z = "Rifle_Burst" } },
		[2] = { displayName = "Rifle Kit II", abilities = { Z = "Rifle_Burst", X = "Rifle_StockBash" } },
		[3] = {
			displayName = "Rifle Kit III",
			abilities = { Z = "Rifle_Burst", X = "Rifle_StockBash", C = "Rifle_AimedShot" },
		},
	},
}

return table.freeze(Kits)
