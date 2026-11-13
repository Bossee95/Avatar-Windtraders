--!strict
--[[
	CombatVFXController: plays hit, block and dodge effects for everyone's
	combat (GDD §6). Purely cosmetic; the server never waits on it.

	Which effect plays for which event is in Shared.Combat.Config.Effects.
	The particle folders live in the place at ReplicatedStorage.VFX.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Effects = require(Shared.Combat.Config.Effects)

local CombatVFXController = {}

local function folder(name: string?): Instance?
	if not name then
		return nil
	end
	local vfx = ReplicatedStorage:FindFirstChild(Effects.FolderName)
	return vfx and vfx:FindFirstChild(name)
end

local function rootOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function emit(model: any, folderName: string?)
	local source = folder(folderName)
	local root = rootOf(model)
	if not source or not root then
		return
	end
	local holder = Instance.new("Attachment")
	holder.Name = "CombatVFX"
	holder.Parent = root
	for _, child in source:GetChildren() do
		if child:IsA("ParticleEmitter") then
			local emitter = child:Clone()
			emitter.Rate = 0
			emitter.Parent = holder
			local count = emitter:GetAttribute("BurstCount")
			emitter:Emit(if type(count) == "number" then count else Effects.BurstCount)
		end
	end
	Debris:AddItem(holder, Effects.Lifetime)
end

local function flash(model: any)
	local template = folder(Effects.HitFlash)
	local highlight = template and template:FindFirstChildWhichIsA("Highlight")
	if not highlight or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local clone = highlight:Clone()
	clone.Adornee = model
	clone.Parent = model
	Debris:AddItem(clone, Effects.HitFlashTime)
end

function CombatVFXController:Start()
	Net.OnEvent("CombatHit", function(_attacker: Model, _actionId: string, targets: { Model })
		if type(targets) ~= "table" then
			return
		end
		for _, target in targets do
			emit(target, Effects.Hit)
			flash(target)
		end
	end)
	Net.OnEvent("CombatDefense", function(character: Model, kind: string)
		emit(character, Effects.Defense[kind])
	end)
end

return CombatVFXController
