--!strict
--[[
	SettingsController: the player's settings (Shared.Settings.SettingsConfig).

	Loads them from the server on start, applies them on this client, and
	saves changes back (debounced, so dragging a slider sends one save).

	  Music / sound effects volume  -> SoundService SoundGroups "Music" / "SFX"
	  Low graphics                  -> shadows and post effects off
	  Show hitboxes                 -> read by HitboxViewController

	Public API:
	  SettingsController:Get(key) -> value
	  SettingsController:Set(key, value)
	  SettingsController.Changed  Signal(key, value)
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local SettingsConfig = require(Shared.Settings.SettingsConfig)

local SAVE_DELAY = 0.8

local SettingsController = {}

SettingsController.Changed = Signal.new() -- (key, value)

local values: { [string]: number | boolean } = SettingsConfig.sanitise(nil)
local saveToken = 0

local function soundGroup(name: string): SoundGroup
	local group = SoundService:FindFirstChild(name)
	if group and group:IsA("SoundGroup") then
		return group
	end
	local created = Instance.new("SoundGroup")
	created.Name = name
	created.Parent = SoundService
	return created
end

-- Lighting state before low graphics was turned on, to put back.
local savedLighting: { shadows: boolean, effects: { [Instance]: boolean } }? = nil

local function isPostEffect(instance: Instance): boolean
	return instance:IsA("PostEffect") and instance.Name ~= "InventoryBlur"
end

local function applyLowGraphics(on: boolean)
	if on and not savedLighting then
		local effects = {}
		for _, child in Lighting:GetChildren() do
			if isPostEffect(child) then
				effects[child] = (child :: PostEffect).Enabled
				;(child :: PostEffect).Enabled = false
			end
		end
		savedLighting = { shadows = Lighting.GlobalShadows, effects = effects }
		Lighting.GlobalShadows = false
	elseif not on and savedLighting then
		Lighting.GlobalShadows = savedLighting.shadows
		for effect, enabled in savedLighting.effects do
			if effect.Parent then
				(effect :: PostEffect).Enabled = enabled
			end
		end
		savedLighting = nil
	end
end

local function apply(key: string, value: number | boolean)
	if key == "musicVolume" then
		soundGroup(SettingsConfig.MusicGroup).Volume = value :: number
	elseif key == "sfxVolume" then
		soundGroup(SettingsConfig.SfxGroup).Volume = value :: number
	elseif key == "lowGraphics" then
		applyLowGraphics(value == true)
	end
	-- showHitboxes is read when an attack starts (HitboxViewController).
end

local function applyAll()
	for key, value in values do
		apply(key, value)
	end
end

function SettingsController:Get(key: string): any
	return values[key]
end

function SettingsController:Set(key: string, value: number | boolean)
	local merged = table.clone(values)
	merged[key] = value
	local clean = SettingsConfig.sanitise(merged)
	if clean[key] == values[key] then
		return
	end
	values[key] = clean[key]
	apply(key, clean[key])
	SettingsController.Changed:Fire(key, clean[key])

	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DELAY, function()
		if token == saveToken then
			Net.Invoke("SaveSettings", values)
		end
	end)
end

function SettingsController:Start()
	applyAll()
	local saved = Net.Invoke("GetSettings")
	if type(saved) == "table" then
		values = SettingsConfig.sanitise(saved)
		applyAll()
		for key, value in values do
			SettingsController.Changed:Fire(key, value)
		end
	end
	-- Effects added later (e.g. by a map) also respect low graphics.
	Lighting.ChildAdded:Connect(function(child)
		if savedLighting and isPostEffect(child) then
			savedLighting.effects[child] = (child :: PostEffect).Enabled
			;(child :: PostEffect).Enabled = false
		end
	end)
end

return SettingsController
