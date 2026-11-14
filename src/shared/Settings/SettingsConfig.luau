--!strict
--[[
	SettingsConfig: the player settings on the inventory's Settings page.

	Each setting has a default and a kind. The server saves them in the
	account-scope "Settings" section; the client applies them
	(Client.Controllers.SettingsController).

	Sounds follow the volume sliders when they play through the SoundGroups
	named here (SoundService.Music / SoundService.SFX). The client creates the
	groups if the place doesn't have them.
]]

export type Setting = {
	key: string,
	label: string,
	kind: "Slider" | "Toggle",
	default: number | boolean,
	help: string,
}

local SettingsConfig = {}

SettingsConfig.MusicGroup = "Music"
SettingsConfig.SfxGroup = "SFX"

SettingsConfig.List = {
	{
		key = "musicVolume",
		label = "Music volume",
		kind = "Slider",
		default = 0.5,
		help = "Background music.",
	},
	{
		key = "sfxVolume",
		label = "Sound effects volume",
		kind = "Slider",
		default = 0.8,
		help = "Combat hits, abilities and other sounds.",
	},
	{
		key = "lowGraphics",
		label = "Low graphics",
		kind = "Toggle",
		default = false,
		help = "Turns off shadows and post-processing effects for a smoother frame rate.",
	},
	{
		key = "showHitboxes",
		label = "Show hitboxes",
		kind = "Toggle",
		default = false,
		help = "Briefly draws the area each of your attacks checks for hits.",
	},
} :: { Setting }

-- Checks a settings table from a client and returns a clean copy with
-- defaults for anything missing or invalid.
function SettingsConfig.sanitise(input: any): { [string]: number | boolean }
	local clean: { [string]: number | boolean } = {}
	local source = if type(input) == "table" then input else {}
	for _, setting in SettingsConfig.List do
		local value = source[setting.key]
		if setting.kind == "Slider" then
			clean[setting.key] = if type(value) == "number" and value == value
				then math.clamp(value, 0, 1)
				else setting.default
		else
			clean[setting.key] = if type(value) == "boolean" then value else setting.default
		end
	end
	return clean
end

return SettingsConfig
