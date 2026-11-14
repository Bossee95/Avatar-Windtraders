--[[
	Remotes for the inventory's Customise page (weapon skins and accessories).

	Payloads:
		CosmeticsState  S->C  state (see CosmeticService:Describe)
		GetCosmetics    C->S  () -> state
		EquipSkin       C->S  weaponType, skinId? (nil clears) -> ok, err
		SetAccessory    C->S  accessoryId, wear: boolean -> ok, err
]]

return {
	Events = {
		CosmeticsState = true,
	},
	Functions = {
		GetCosmetics = true,
		EquipSkin = true,
		SetAccessory = true,
	},
}
