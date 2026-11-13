--!strict
--[[
	CombatHUDController: a plain combat readout so the systems are usable
	while the real UI is designed: block charges, dodge charges, the
	downed timer and what you are carrying or executing.

	Replace freely; it only reads DefenseController's public API and the
	Knocked / KnockAction attributes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatSettings = require(Shared.Combat.Config.CombatSettings)

local DefenseController = require(script.Parent.DefenseController)

local LocalPlayer = Players.LocalPlayer

local CombatHUDController = {}

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for k, v in props do
		(instance :: any)[k] = v
	end
	instance.Parent = parent
	return instance
end

local function pips(filled: number, total: number): string
	return string.rep("■", math.max(0, filled)) .. string.rep("□", math.max(0, total - filled))
end

function CombatHUDController:Start()
	local gui = make("ScreenGui", {
		Name = "CombatHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
	}, LocalPlayer:WaitForChild("PlayerGui"))
	local label = make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(0, 360, 0, 22),
		BackgroundTransparency = 1,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.5,
		Font = Enum.Font.GothamMedium,
		TextSize = 16,
		Text = "",
	}, gui)
	local status = make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -38),
		Size = UDim2.new(0, 360, 0, 22),
		BackgroundTransparency = 1,
		TextColor3 = Color3.fromRGB(255, 210, 120),
		TextStrokeTransparency = 0.5,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Text = "",
	}, gui)

	local function refreshDefense()
		local s = DefenseController:GetState()
		label.Text = string.format(
			"Block %s   Dodge %s%s",
			pips(s.blockCounts, s.maxBlock),
			pips(s.dodgeCharges, s.maxDodge),
			if s.blocking then "   (blocking)" else ""
		)
	end
	DefenseController.StateChanged:Connect(refreshDefense)
	refreshDefense()

	RunService.Heartbeat:Connect(function()
		local character = LocalPlayer.Character
		local mode = character and character:GetAttribute("Knocked")
		local action = LocalPlayer:GetAttribute("KnockAction")
		if mode == "Down" then
			local recoverAt = character and character:GetAttribute("KnockRecoverAt")
			local left = if type(recoverAt) == "number"
				then math.max(0, recoverAt - workspace:GetServerTimeNow())
				else CombatSettings.Knock.Duration
			status.Text = string.format("Downed (%.0fs)", left)
		elseif mode == "Carried" then
			status.Text = "Being carried"
		elseif mode == "Gripped" then
			status.Text = "Being executed"
		else
			if action == "Carrying" then
				status.Text = "Carrying  (V to drop)"
			elseif action == "Executing" then
				status.Text = "Executing  (B to stop)"
			else
				status.Text = ""
			end
		end
	end)
end

return CombatHUDController
