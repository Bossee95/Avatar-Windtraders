--[[
	SettingsService: saves each player's settings (music and sound volume, low
	graphics, show hitboxes) in the account-scope "Settings" section, so they
	follow the player across characters and servers. The client applies them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local SettingsConfig = require(ReplicatedStorage.Shared.Settings.SettingsConfig)

local SettingsService = {}

local SECTION = "Settings"

local function dataService()
	return Loader.Get("DataService")
end

function SettingsService:Init()
	dataService():RegisterSection(SECTION, { scope = "Account", default = { values = {} } })
end

function SettingsService:Get(player)
	local section = dataService():GetAccountSection(player, SECTION)
	return SettingsConfig.sanitise(section and section.values)
end

function SettingsService:Start()
	Net.OnInvoke("GetSettings", function(player)
		return SettingsService:Get(player)
	end)
	Net.OnInvoke("SaveSettings", function(player, values)
		local section = dataService():GetAccountSection(player, SECTION)
		local clean = SettingsConfig.sanitise(values)
		if section then
			section.values = clean
		end
		return clean
	end, { rateLimit = 2 })
end

return SettingsService
