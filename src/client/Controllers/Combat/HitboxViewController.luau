--!strict
--[[
	HitboxViewController: when the "Show hitboxes" setting is on, briefly
	draws the area each of the local player's attacks checks for hits.

	It is a visual aid only, drawn on this client from the action's config
	(Shared.Combat.Config.Actions) at the moment the hit is checked. Box and
	Radius shapes match the server exactly; Ray and Cone are drawn straight
	ahead of the character, since the real aim isn't sent back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actions = require(Shared.Combat.Config.Actions)

local SettingsController = require(script.Parent.Parent.SettingsController)

local LocalPlayer = Players.LocalPlayer

local SHOW_FOR = 0.25
local COLOR = Color3.fromRGB(255, 70, 90)

local HitboxViewController = {}

local function makePart(shape: Enum.PartType?, size: Vector3, cframe: CFrame)
	local part = Instance.new("Part")
	part.Name = "HitboxView"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = COLOR
	part.Transparency = 0.2
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Parent = workspace
	task.delay(SHOW_FOR, part.Destroy, part)
end

local function draw(character: Model, hitbox: any)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local cf = root.CFrame
	if hitbox.shape == "Box" then
		local range = hitbox.range :: number
		makePart(nil, Vector3.new(hitbox.width, hitbox.height, range), cf * CFrame.new(0, 0, -range / 2))
	elseif hitbox.shape == "Radius" then
		local d = (hitbox.radius :: number) * 2
		makePart(Enum.PartType.Ball, Vector3.new(d, d, d), cf)
	elseif hitbox.shape == "Ray" then
		local range = hitbox.range :: number
		makePart(nil, Vector3.new(0.3, 0.3, range), cf * CFrame.new(0, 1.5, -range / 2))
	elseif hitbox.shape == "Cone" then
		local range = hitbox.range :: number
		local farWidth = 2 * range * math.tan(math.rad((hitbox.angle :: number) / 2))
		makePart(nil, Vector3.new(farWidth, 1, range), cf * CFrame.new(0, 1.5, -range / 2))
	end
end

function HitboxViewController:Start()
	Net.OnEvent("CombatActionStarted", function(character: Model, actionId: string)
		if character ~= LocalPlayer.Character or SettingsController:Get("showHitboxes") ~= true then
			return
		end
		local action = Actions[actionId] :: any
		if not action or not action.hitbox or action.hitbox.shape == "None" then
			return
		end
		local hits = if type(action.hits) == "number" then action.hits else 1
		local interval = if type(action.hitInterval) == "number" then action.hitInterval else 0
		for i = 1, hits do
			task.delay((action.windup or 0) + (i - 1) * interval, function()
				if character.Parent then
					draw(character, action.hitbox)
				end
			end)
		end
	end)
end

return HitboxViewController
