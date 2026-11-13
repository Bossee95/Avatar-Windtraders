--!strict
--[[
	Animation keys used by Actions.luau.

	Every entry is a placeholder (rbxassetid://0). The client skips playing an
	animation whose id is 0, so combat works before any animation is made.
	Replace an id with a real uploaded animation to use it. All variations of
	a weapon type share the M1 entries (GDD §6.2).
]]

local PLACEHOLDER = "rbxassetid://0"

local Animations: { [string]: string } = {
	Bow_M1_1 = PLACEHOLDER,
	Bow_PinningShot = PLACEHOLDER,
	Bow_PowerShot = PLACEHOLDER,
	Bow_Volley = PLACEHOLDER,
	Crit_Bow_Heartseeker = PLACEHOLDER,
	Crit_Bow_Scatter = PLACEHOLDER,
	Crit_Rifle_Overcharge = PLACEHOLDER,
	Crit_Rifle_Pierce = PLACEHOLDER,
	Crit_Spear_Impale = PLACEHOLDER,
	Crit_Spear_Sweep = PLACEHOLDER,
	Crit_Sword_Cleave = PLACEHOLDER,
	Crit_Sword_Execute = PLACEHOLDER,
	G_BattleCry = PLACEHOLDER,
	G_DoubleBarrel = PLACEHOLDER,
	G_Grab = PLACEHOLDER,
	G_SmokeGrenade = PLACEHOLDER,
	Rifle_AimedShot = PLACEHOLDER,
	Rifle_Burst = PLACEHOLDER,
	Rifle_M1_1 = PLACEHOLDER,
	Rifle_StockBash = PLACEHOLDER,
	Spear_M1_1 = PLACEHOLDER,
	Spear_M1_2 = PLACEHOLDER,
	Spear_M1_3 = PLACEHOLDER,
	Spear_Spin = PLACEHOLDER,
	Spear_Thrust = PLACEHOLDER,
	Spear_VaultStrike = PLACEHOLDER,
	Sword_HeavySlash = PLACEHOLDER,
	Sword_Lunge = PLACEHOLDER,
	Sword_M1_1 = PLACEHOLDER,
	Sword_M1_2 = PLACEHOLDER,
	Sword_M1_3 = PLACEHOLDER,
	Sword_M1_4 = PLACEHOLDER,
	Sword_Sweep = PLACEHOLDER,
}

return table.freeze(Animations)
