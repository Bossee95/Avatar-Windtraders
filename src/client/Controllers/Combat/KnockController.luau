--!strict
--[[
	KnockController: input and ragdoll for the downed state (GDD §6.7).

	Controls
	  V  carry the nearest downed character, or drop the one you carry
	  B  execute the nearest downed character, or stop an execution

	KnockService decides everything; this only sends intent and ragdolls the
	local character while its Knocked attribute is "Down". The local client
	owns its character's physics, so the ragdoll pose replicates to others.
	A carried or gripped character is unragdolled so it can be held.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local LocalPlayer = Players.LocalPlayer
local CARRY_KEY = Enum.KeyCode.V
local EXECUTE_KEY = Enum.KeyCode.B

local KnockController = {}

type Saved = {
	joints: { Motor6D | AnimationConstraint },
	added: { Instance },
	walkSpeed: number,
	jumpPower: number,
	hipHeight: number,
}

local saved: Saved? = nil

local function ragdoll(character: Model)
	if saved then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	local s: Saved = {
		joints = {},
		added = {},
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		hipHeight = humanoid.HipHeight,
	}
	for _, joint in character:GetDescendants() do
		-- Newer rigs already carry ball sockets and drive joints with
		-- AnimationConstraints: switching those off is enough.
		if joint:IsA("AnimationConstraint") and joint.Name ~= "Root" and joint.Enabled then
			joint.Enabled = false
			table.insert(s.joints, joint)
			continue
		end
		if joint:IsA("Motor6D") and joint.Part0 and joint.Part1 and joint.Name ~= "RootJoint" then
			local a0 = Instance.new("Attachment")
			a0.CFrame = joint.C0
			a0.Parent = joint.Part0
			local a1 = Instance.new("Attachment")
			a1.CFrame = joint.C1
			a1.Parent = joint.Part1
			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.UpperAngle = 60
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -45
			socket.TwistUpperAngle = 45
			socket.Parent = joint.Parent
			table.insert(s.added, a0)
			table.insert(s.added, a1)
			table.insert(s.added, socket)
			joint.Enabled = false
			table.insert(s.joints, joint)
		end
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part ~= root and not (part.Parent and part.Parent:IsA("Accessory")) then
			if part:GetAttribute("PreRagdollCanCollide") == nil then
				part:SetAttribute("PreRagdollCanCollide", part.CanCollide)
			end
			part.CanCollide = true
		end
	end
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	root.AssemblyLinearVelocity = -root.CFrame.LookVector * 20 + Vector3.new(0, 15, 0)
	saved = s
end

local function unragdoll(character: Model)
	local s = saved
	if not s then
		return
	end
	saved = nil
	for _, inst in s.added do
		inst:Destroy()
	end
	for _, joint in s.joints do
		if joint.Parent then
			joint.Enabled = true
		end
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			local previous = part:GetAttribute("PreRagdollCanCollide")
			if previous ~= nil then
				part.CanCollide = previous
				part:SetAttribute("PreRagdollCanCollide", nil)
			end
		end
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = CFrame.new(root.Position + Vector3.new(0, 2, 0))
			* CFrame.Angles(0, select(2, root.CFrame:ToEulerAnglesYXZ()), 0)
	end
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		humanoid.WalkSpeed = s.walkSpeed
		humanoid.JumpPower = s.jumpPower
		humanoid.HipHeight = s.hipHeight
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local function watch(character: Model)
	saved = nil
	local function update()
		local mode = character:GetAttribute("Knocked")
		if mode == "Down" then
			ragdoll(character)
		else
			unragdoll(character)
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				-- Held by someone: limp but not ragdolled. Up again: stand.
				humanoid.PlatformStand = mode ~= nil
			end
		end
	end
	character:GetAttributeChangedSignal("Knocked"):Connect(update)
	update()
end

function KnockController:Start()
	LocalPlayer.CharacterAdded:Connect(watch)
	if LocalPlayer.Character then
		task.spawn(watch, LocalPlayer.Character)
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == CARRY_KEY then
			Net.Fire("KnockCarry")
		elseif input.KeyCode == EXECUTE_KEY then
			Net.Fire("KnockExecute")
		end
	end)
end

return KnockController
