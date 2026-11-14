--[[
	Remotes for player settings (inventory, Settings page).

	Payloads:
		GetSettings   C->S  () -> settings
		SaveSettings  C->S  settings -> settings (cleaned, as saved)
]]

return {
	Events = {},
	Functions = {
		GetSettings = true,
		SaveSettings = true,
	},
}
