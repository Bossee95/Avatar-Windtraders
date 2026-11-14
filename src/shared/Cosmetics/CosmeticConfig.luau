--[[
	CosmeticConfig: tunables for accessories worn from the inventory's
	Customise page.

	Accessories are the Accessory instances in ServerStorage.CosmeticModels.
	Each can have a "DisplayName" attribute (shown instead of its name) and a
	"Slot" attribute (e.g. "Hat", "Face", "Back"). Only one accessory per slot
	is worn at a time; wearing another in the same slot swaps them.
]]

return {
	-- Most accessories a player can wear at once.
	MaxAccessories = 4,
}
