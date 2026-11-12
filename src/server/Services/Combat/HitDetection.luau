--!strict
--[[
	Server-authoritative hit detection (GDD §6.1).

	The client only sends which input it pressed and, for ranged actions, an
	aim direction. Every hitbox is built from the server's own copy of the
	attacker's position, so a client cannot extend its reach or hit through
	walls. Aim directions are normalised and their pitch clamped.

	Shapes (from Actions.luau):
	  Box     box of width x height x range directly in front of the attacker
	  Radius  sphere around the attacker
	  Ray     first target along the aim direction, stopped by terrain/walls
	  Cone    every target within range and angle of the aim, with line of
	          sight, nearest first
	  None    no targets
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.Shared.Combat.Config.Actions)
local CombatSettings = require(ReplicatedStorage.Shared.Combat.Config.CombatSettings)

export type Hit = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	distance: number,
}

local HitDetection = {}

function HitDetection.getRoot(model: Model?): BasePart?
	if not model then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function aliveHumanoid(model: Model): Humanoid?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

-- Finds the combat target (a model with a living Humanoid and a root)
-- that owns a part.
local function targetFromPart(part: BasePart): (Model?, Humanoid?, BasePart?)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = aliveHumanoid(model)
		local root = HitDetection.getRoot(model)
		if humanoid and root then
			if not CombatSettings.AllowNonPlayerTargets and not Players:GetPlayerFromCharacter(model) then
				return nil, nil, nil
			end
			return model, humanoid, root
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil, nil
end

-- Turns a client-sent aim into a safe unit vector, or falls back to the
-- attacker's facing.
function HitDetection.sanitiseAim(aim: any, root: BasePart): Vector3
	local fallback = root.CFrame.LookVector
	if typeof(aim) ~= "Vector3" then
		return fallback
	end
	local v = aim :: Vector3
	if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z or v.Magnitude < 1e-3 or v.Magnitude > 1e3 then
		return fallback
	end
	v = v.Unit
	local maxPitch = math.rad(CombatSettings.MaxAimPitchDegrees)
	local pitch = math.asin(math.clamp(v.Y, -1, 1))
	if math.abs(pitch) > maxPitch then
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude < 1e-3 then
			flat = Vector3.new(fallback.X, 0, fallback.Z)
		end
		flat = flat.Unit
		local clamped = math.sign(pitch) * maxPitch
		v = flat * math.cos(clamped) + Vector3.new(0, math.sin(clamped), 0)
	end
	return v
end

local function overlapParams(attacker: Model): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker }
	return params
end

local function rayParams(exclude: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return params
end

local function collect(parts: { BasePart }, origin: Vector3): { Hit }
	local seen: { [Model]: boolean } = {}
	local hits: { Hit } = {}
	for _, part in parts do
		local model, humanoid, root = targetFromPart(part)
		if model and humanoid and root and not seen[model] then
			seen[model] = true
			table.insert(hits, {
				model = model,
				humanoid = humanoid,
				root = root,
				distance = (root.Position - origin).Magnitude,
			})
		end
	end
	table.sort(hits, function(a, b)
		return a.distance < b.distance
	end)
	return hits
end

local function eyeOrigin(attacker: Model, root: BasePart): Vector3
	local head = attacker:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return root.Position + Vector3.new(0, 1.5, 0)
end

local function hasLineOfSight(origin: Vector3, target: Hit, attacker: Model): boolean
	local result = workspace:Raycast(origin, target.root.Position - origin, rayParams({ attacker, target.model }))
	return result == nil
end

function HitDetection.query(attacker: Model, action: Actions.Action, aim: any): { Hit }
	local root = HitDetection.getRoot(attacker)
	if not root then
		return {}
	end
	local hitbox = action.hitbox
	local shape = hitbox.shape
	local hits: { Hit }

	if shape == "None" then
		return {}
	elseif shape == "Box" then
		local range = hitbox.range :: number
		local cf = root.CFrame * CFrame.new(0, 0, -range / 2)
		local size = Vector3.new(hitbox.width :: number, hitbox.height :: number, range)
		local parts = workspace:GetPartBoundsInBox(cf, size, overlapParams(attacker))
		hits = collect(parts, root.Position)
	elseif shape == "Radius" then
		local parts = workspace:GetPartBoundsInRadius(root.Position, hitbox.radius :: number, overlapParams(attacker))
		hits = collect(parts, root.Position)
	elseif shape == "Ray" then
		local origin = eyeOrigin(attacker, root)
		local dir = HitDetection.sanitiseAim(aim, root)
		local result = workspace:Raycast(origin, dir * (hitbox.range :: number), rayParams({ attacker }))
		if not result or not result.Instance:IsA("BasePart") then
			return {}
		end
		hits = collect({ result.Instance :: BasePart }, origin)
		if hits[1] then
			hits[1].distance = (result.Position - origin).Magnitude
		end
	elseif shape == "Cone" then
		local origin = eyeOrigin(attacker, root)
		local dir = HitDetection.sanitiseAim(aim, root)
		local range = hitbox.range :: number
		local halfAngle = math.rad((hitbox.angle :: number) / 2)
		local parts = workspace:GetPartBoundsInRadius(origin, range, overlapParams(attacker))
		hits = {}
		for _, hit in collect(parts, origin) do
			local offset = hit.root.Position - origin
			if offset.Magnitude <= range then
				local angle = if offset.Magnitude < 1e-3 then 0 else math.acos(math.clamp(offset.Unit:Dot(dir), -1, 1))
				if angle <= halfAngle and hasLineOfSight(origin, hit, attacker) then
					table.insert(hits, hit)
				end
			end
		end
	else
		return {}
	end

	if action.maxTargets and #hits > action.maxTargets then
		local trimmed = table.create(action.maxTargets)
		for i = 1, action.maxTargets do
			trimmed[i] = hits[i]
		end
		hits = trimmed
	end
	return hits
end

return HitDetection
