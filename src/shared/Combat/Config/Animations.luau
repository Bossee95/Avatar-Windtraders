--!strict
--[[
	Animation keys used by Actions.luau and the client controllers.

	An id of rbxassetid://0 is a placeholder: the client skips it, so combat
	works before an animation is made. Replace it with a real uploaded
	animation to use it. All variations of a weapon type share the M1 entries
	(GDD §6.2). The spear M1 set and the movement/defence set come from the
	original Studio combat. Animations only load online if the experience
	owner owns them.
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
	Spear_M1_1 = "rbxassetid://134070983154513",
	Spear_M1_2 = "rbxassetid://85112321184046",
	Spear_M1_3 = "rbxassetid://103181723554176",
	Spear_M1_4 = "rbxassetid://82631986068671",
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

	-- Movement and defence, shared by every weapon (from the original Studio combat).
	Idle = "rbxassetid://124949013351663",
	Sprint = "rbxassetid://98901673302379",
	DodgeForward = "rbxassetid://70931227289473",
	DodgeBack = "rbxassetid://138176610635978",
	DodgeLeft = "rbxassetid://130218891822906",
	DodgeRight = "rbxassetid://93257231572674",
	AirDash = "rbxassetid://91906352141366",
	LedgeMount = "rbxassetid://86729095683998",
	Stunned = "rbxassetid://92133394414548",
	BlockIdle = "rbxassetid://98767795375773",
	PerfectBlock = "rbxassetid://73330540138744",
	BlockBroken = "rbxassetid://110538582009996",
	BlockHit = "rbxassetid://110538582009996",
	Spear_Idle = "rbxassetid://107767334720754",
}

return table.freeze(Animations)
