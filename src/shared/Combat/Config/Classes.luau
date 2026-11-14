--!strict
--[[
	Combat classes (Bossee, 2026-11-14).

	A class locks a character to one weapon type. A Lancer only ever wields
	their single spear: there is no quick-swapping between weapons. The
	character's weapon is equipped automatically on spawn; players never
	pick a weapon themselves.

	Which weapon:
	  1. a weapon item of the class's weapon type that the character owns
	     (crafted or acquired variations, each with its own R Critical), or
	  2. the class's defaultVariation if they own none.

	The kit level (Z/X/C) still comes from character.kits[weaponType],
	granted by the Loreteam. A character's class is set by staff with
	/class <player> <classId> (AssignKits permission) and defaults to
	CombatSettings.DefaultClass.

	Fields
	  displayName       Shown to players. Change freely.
	  weaponType        WeaponTypes key this class is locked to.
	  defaultVariation  Variations key used when the character owns no
	                    weapon of that type.
]]

export type Class = {
	displayName: string,
	weaponType: string,
	defaultVariation: string,
}

local Classes: { [string]: Class } = {
	Lancer = { displayName = "Lancer", weaponType = "Spear", defaultVariation = "Spear_Standard" },
	Swordsman = { displayName = "Swordsman", weaponType = "Sword", defaultVariation = "Sword_Standard" },
	Archer = { displayName = "Archer", weaponType = "Bow", defaultVariation = "Bow_Standard" },
	Marksman = { displayName = "Marksman", weaponType = "Rifle", defaultVariation = "Rifle_Standard" },
}

return table.freeze(Classes)
