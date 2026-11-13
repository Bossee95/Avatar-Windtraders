--!strict
--[[
	Weapon types (GDD §5.4, §6.2).

	A weapon type owns the fundamental M1 combo. Every variation of the same
	type shares this combo and its animations, so a new sword never needs a
	new basic combat system. Only the R Critical differs per variation
	(see Variations.luau).

	Fields
	  displayName     Shown to players. Change freely.
	  m1Combo         Ordered list of action ids (Actions.luau, kind = "M1").
	  comboResetTime  Seconds after the last M1 finishes before the combo
	                  restarts at step 1.
	  comboEndlag     Extra lockout after the final step of the combo.
	  placeholderModel  Size/colour of the temporary part welded to the hand
	                  until real models exist.
]]

export type WeaponType = {
	displayName: string,
	m1Combo: { string },
	comboResetTime: number,
	comboEndlag: number,
	placeholderModel: { size: { number }, color: { number } },
}

local WeaponTypes: { [string]: WeaponType } = {
	Sword = {
		displayName = "Sword",
		m1Combo = { "Sword_M1_1", "Sword_M1_2", "Sword_M1_3", "Sword_M1_4" },
		comboResetTime = 1.2,
		comboEndlag = 0.6,
		placeholderModel = { size = { 0.3, 0.3, 4 }, color = { 190, 190, 200 } },
	},
	Spear = {
		displayName = "Spear",
		m1Combo = { "Spear_M1_1", "Spear_M1_2", "Spear_M1_3" },
		comboResetTime = 1.3,
		comboEndlag = 0.7,
		placeholderModel = { size = { 0.25, 0.25, 7 }, color = { 140, 100, 60 } },
	},
	Bow = {
		displayName = "Bow",
		m1Combo = { "Bow_M1_1" },
		comboResetTime = 0,
		comboEndlag = 0,
		placeholderModel = { size = { 0.2, 4, 0.2 }, color = { 110, 80, 50 } },
	},
	Rifle = {
		displayName = "Rifle",
		m1Combo = { "Rifle_M1_1" },
		comboResetTime = 0,
		comboEndlag = 0,
		placeholderModel = { size = { 0.4, 0.6, 3.5 }, color = { 60, 60, 60 } },
	},
}

return table.freeze(WeaponTypes)
