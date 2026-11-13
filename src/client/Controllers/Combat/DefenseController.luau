--!strict
--[[
	DefenseController: client input and presentation for blocking and
	dodging (GDD §6.6).

	Controls
	  F (hold)  block. Raising it just before a hit lands is a perfect block.
	  Q         dodge in the direction you are moving (backwards if standing still).

	The server decides every outcome (CombatService + Shared.Combat.Defense).
	The client only asks, then moves its own character for a dodge (player
	characters are simulated by their client) and plays animations.

	Public API for HUD code:
	  DefenseController:GetState() -> { blocking, blockCounts, maxBlock, dodgeCharges, maxDodge }
	  DefenseController.StateChanged  Signal(state)
	  DefenseController.Event         Signal(kind, character, extra)  -- every CombatDefense event
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Animations = require(Shared.Combat.Config.Animations)
local CombatSettings = require(Shared.Combat.Config.CombatSettings)

local LocalPlayer = Players.LocalPlayer
local PLACEHOLDER_ID = "rbxassetid://0"
local BLOCK_KEY = Enum.KeyCode.F
local DODGE_KEY = Enum.KeyCode.Q

local DefenseController = {}
DefenseController.StateChanged = Signal.new()
DefenseController.Event = Signal.new()

local state = {
	blocking = false,
	blockCounts = CombatSettings.Block.MaxCounts,
	maxBlock = CombatSettings.Block.MaxCounts,
	dodgeCharges = CombatSettings.Dodge.MaxCharges,
	maxDodge = CombatSettings.Dodge.MaxCharges,
}

local trackCache: { [string]: AnimationTrack } = {}
local cachedAnimator: Animator? = nil
local slowedFrom: number? = nil

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

local function getTrack(key: string): AnimationTrack?
	local id = Animations[key]
	if not id or id == PLACEHOLDER_ID then
		return nil
	end
	local animator = getAnimator()
	if not animator then
		return nil
	end
	local track = trackCache[key]
	if not track then
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		track = animator:LoadAnimation(animation)
		trackCache[key] = track
	end
	return track
end

local function play(key: string, looped: boolean?)
	local track = getTrack(key)
	if track then
		track.Looped = looped == true
		track:Play(0.05)
	end
end

local function stop(key: string)
	local track = trackCache[key]
	if track then
		track:Stop(0.1)
	end
end

local function getHumanoid(): Humanoid?
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Block slows the defender. Applied on the client because the client owns
-- its character's movement; the server never trusts speed from the client.
local function setBlockVisuals(blocking: boolean)
	local humanoid = getHumanoid()
	if blocking then
		play("BlockIdle", true)
		if humanoid and not slowedFrom then
			slowedFrom = humanoid.WalkSpeed
			humanoid.WalkSpeed = humanoid.WalkSpeed * CombatSettings.Block.WalkSpeedMultiplier
		end
	else
		stop("BlockIdle")
		if humanoid and slowedFrom then
			-- Don't undo a stun that froze movement meanwhile.
			if humanoid.WalkSpeed > 0 then
				humanoid.WalkSpeed = slowedFrom
			end
		end
		slowedFrom = nil
	end
end

local function dodgeDirection(): Vector3?
	local character = LocalPlayer.Character
	local humanoid = getHumanoid()
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return nil
	end
	local move = humanoid.MoveDirection
	local flat = Vector3.new(move.X, 0, move.Z)
	if flat.Magnitude < 0.1 then
		local look = root.CFrame.LookVector
		flat = -Vector3.new(look.X, 0, look.Z)
	end
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return flat.Unit
end

local function dodgeAnimationKey(root: BasePart, direction: Vector3): string
	local look = root.CFrame.LookVector
	local right = root.CFrame.RightVector
	local forward = Vector3.new(look.X, 0, look.Z).Unit:Dot(direction)
	local side = Vector3.new(right.X, 0, right.Z).Unit:Dot(direction)
	if math.abs(forward) >= math.abs(side) then
		return if forward >= 0 then "DodgeForward" else "DodgeBack"
	end
	return if side >= 0 then "DodgeRight" else "DodgeLeft"
end

-- Moves the local character for the dodge. Called once the server accepts it.
local function performDodge(direction: Vector3)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	play(dodgeAnimationKey(root, direction))
	local duration = CombatSettings.Dodge.Duration
	local speed = CombatSettings.Dodge.Distance / duration
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if os.clock() - started >= duration or not root.Parent then
			connection:Disconnect()
			-- Stop the burst so the character doesn't keep sliding.
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
			return
		end
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(direction.X * speed, v.Y, direction.Z * speed)
	end)
end

function DefenseController:GetState()
	return table.clone(state)
end

function DefenseController:Start()
	Net.OnEvent("CombatDefenseState", function(newState)
		if type(newState) ~= "table" then
			return
		end
		local wasBlocking = state.blocking
		for k, v in newState do
			(state :: any)[k] = v
		end
		if state.blocking ~= wasBlocking then
			setBlockVisuals(state.blocking)
		end
		DefenseController.StateChanged:Fire(DefenseController:GetState())
	end)

	Net.OnEvent("CombatDefense", function(character: Model, kind: string, extra: any)
		DefenseController.Event:Fire(kind, character, extra)
		if character ~= LocalPlayer.Character then
			return
		end
		if kind == "Dodge" and typeof(extra) == "Vector3" then
			performDodge(extra)
		elseif kind == "PerfectBlock" then
			play("PerfectBlock")
		elseif kind == "BlockBroken" then
			play("BlockBroken")
		elseif kind == "Blocked" then
			play("BlockHit")
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == BLOCK_KEY then
			Net.Fire("CombatBlock", true)
		elseif input.KeyCode == DODGE_KEY then
			local direction = dodgeDirection()
			if direction then
				Net.Fire("CombatDodge", direction)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == BLOCK_KEY then
			Net.Fire("CombatBlock", false)
		end
	end)

	LocalPlayer.CharacterAdded:Connect(function()
		slowedFrom = nil
		state.blocking = false
	end)
end

return DefenseController
