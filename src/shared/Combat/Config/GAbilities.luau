--!strict
--[[
	G abilities (GDD §6.5).

	G abilities are individual abilities, not another tier of a weapon kit.
	They are assigned to a character separately (purchase, lore award,
	event, contribution) and recorded in the character record.

	A character may hold several G abilities but has one G key, so they pick
	one with SelectGAbility. Selection follows the same out-of-combat rule as
	weapon switching.

	Fields
	  action          Action id in Actions.luau (kind = "G").
	  requiresWeapon  If true, a weapon must be equipped to use it.
	  allowedWeaponTypes  Optional whitelist of weapon types.

	Cooldowns, damage, range and duration live on the action. These are
	placeholders until GDD §19.6 is settled.
]]

export type GAbility = {
	displayName: string,
	action: string,
	requiresWeapon: boolean,
	allowedWeaponTypes: { string }?,
}

local GAbilities: { [string]: GAbility } = {
	BattleCry = { displayName = "Battle Cry", action = "G_BattleCry", requiresWeapon = false },
	Grab = { displayName = "Grab", action = "G_Grab", requiresWeapon = false },
	SmokeGrenade = { displayName = "Smoke Grenade", action = "G_SmokeGrenade", requiresWeapon = false },
	DoubleBarrel = {
		displayName = "Double-Barrel Shotgun",
		action = "G_DoubleBarrel",
		requiresWeapon = false,
	},
}

return table.freeze(GAbilities)
