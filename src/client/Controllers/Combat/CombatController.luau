--!strict
--[[
	CombatController: client input and presentation for combat.

	The client never decides whether an attack is allowed or what it hits.
	It sends the pressed input (and an aim direction for ranged actions) to
	CombatService, then plays animations when the server confirms an action.

	Controls (GDD §5.4):
	  M1  basic attack / combo (hold to keep attacking)
	  Z X C  kit abilities
	  R   Critical attack of the equipped variation (right-click does nothing)
	  G   selected G ability

	Animations come from Shared.Combat.Config.Animations. Placeholder ids
	(rbxassetid://0) are skipped, so combat works before animations exist.

	Weapons are class-locked (Shared.Combat.Config.Classes): the server
	equips your class weapon on spawn, and there is no client equip or
	weapon swap. A Lancer only ever holds their spear.

	Public API for UI code:
	  CombatController:SelectGAbility(abilityId?) -> (ok, err?)
	  CombatController:GetState() -> { variationId?, gAbilityId?, inCombat, cooldowns }
	  CombatController.StateChanged  Signal(state)
	  CombatController.Notice        Signal(kind, ...)  -- rejections, forced unequips

	Studio only: key 6 cycles G abilities. This binding does not exist in a
	live server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Animations = require(Shared.Combat.Config.Animations)
local Actions = require(Shared.Combat.Config.Actions)
local GAbilities = require(Shared.Combat.Config.GAbilities)
local Push = require(Shared.Combat.Push)
local UIState = require(script.Parent.Parent.Parent.UIState)

local LocalPlayer = Players.LocalPlayer

local PLACEHOLDER_ID = "rbxassetid://0"
local M1_REPEAT_INTERVAL = 0.1

local KEY_TO_INPUT: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Z] = "Z",
	[Enum.KeyCode.X] = "X",
	[Enum.KeyCode.C] = "C",
	[Enum.KeyCode.R] = "R",
	[Enum.KeyCode.G] = "G",
}

local CombatController = {}
CombatController.StateChanged = Signal.new()
CombatController.Notice = Signal.new()

local state = {
	variationId = nil :: string?,
	gAbilityId = nil :: string?,
	inCombat = false,
	cooldowns = {} :: { [string]: number },
}

local trackCache: { [string]: AnimationTrack } = {}
local cachedAnimator: Animator? = nil
local m1Held = false

local function getAnimator(): Animator?
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator ~= cachedAnimator then
		trackCache = {}
		cachedAnimator = animator
	end
	return animator
end

local function playAnimation(key: string, speed: number?)
	local id = Animations[key]
	if not id or id == PLACEHOLDER_ID then
		return
	end
	local animator = getAnimator()
	if not animator then
		return
	end
	local track = trackCache[key]
	if not track then
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		track = animator:LoadAnimation(animation)
		trackCache[key] = track
	end
	track:Play(0.05, 1, speed or 1)
end

-- Where the player is aiming: from the head towards the mouse hit point.
local function getAim(): Vector3?
	local character = LocalPlayer.Character
	local head = character and character:FindFirstChild("Head")
	local camera = workspace.CurrentCamera
	if not head or not head:IsA("BasePart") or not camera then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character :: Model }
	local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local target = if result then result.Position else ray.Origin + ray.Direction * 1000
	local dir = target - head.Position
	if dir.Magnitude < 1e-3 then
		return nil
	end
	return dir.Unit
end

local function send(input: string)
	Net.Fire("CombatUseAction", input, getAim())
end

function CombatController:SelectGAbility(abilityId: string?): (boolean, string?)
	return Net.Invoke("CombatSelectGAbility", abilityId)
end

function CombatController:GetState()
	return table.clone(state)
end

local function bindStudioDebugKeys()
	local gList = {}
	for id in GAbilities do
		table.insert(gList, id)
	end
	table.sort(gList)
	local gIndex = 0

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UIState.IsMenuOpen() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Six and #gList > 0 then
			gIndex = gIndex % #gList + 1
			print("[Combat] select G", gList[gIndex], CombatController:SelectGAbility(gList[gIndex]))
		end
	end)
	print("[Combat] Studio key: 6 cycles G ability")
end

function CombatController:Start()
	Net.OnEvent("CombatState", function(newState)
		state.variationId = newState.variationId
		state.gAbilityId = newState.gAbilityId
		state.inCombat = newState.inCombat == true
		state.cooldowns = newState.cooldowns or {}
		CombatController.StateChanged:Fire(CombatController:GetState())
	end)

	Net.OnEvent("CombatActionStarted", function(character: Model, actionId: string)
		-- Only the owner plays the animation; it replicates to everyone else.
		if character ~= LocalPlayer.Character then
			return
		end
		local action = Actions[actionId]
		if action then
			playAnimation(action.animation, action.animationSpeed)
		end
	end)

	Net.OnEvent("CombatKnockback", function(velocity: Vector3)
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and typeof(velocity) == "Vector3" then
			Push.apply(root, velocity)
		end
	end)

	Net.OnEvent("CombatNotice", function(kind: string, ...)
		CombatController.Notice:Fire(kind, ...)
		if RunService:IsStudio() then
			print("[Combat]", kind, ...)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UIState.IsMenuOpen() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if m1Held then
				return
			end
			m1Held = true
			task.spawn(function()
				while m1Held do
					send("M1")
					task.wait(M1_REPEAT_INTERVAL)
				end
			end)
		else
			local mapped = KEY_TO_INPUT[input.KeyCode]
			if mapped then
				send(mapped)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			m1Held = false
		end
	end)

	if RunService:IsStudio() then
		bindStudioDebugKeys()
	end
end

return CombatController
