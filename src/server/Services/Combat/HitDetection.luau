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
local RunService = game:GetService("RunService")

local Actions = require(ReplicatedStorage.Shared.Combat.Config.Actions)
local CombatSettings = require(ReplicatedStorage.Shared.Combat.Config.CombatSettings)
local LagHistory = require(ReplicatedStorage.Shared.Combat.LagHistory)

local LAG = CombatSettings.LagCompensation

export type Hit = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	distance: number,
}

export type StructureHit = {
	model: Model,
	distance: number,
}

-- Returns the registered structure a part belongs to, if any.
export type StructureLookup = (BasePart) -> Model?

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

local function collectStructures(
	parts: { BasePart },
	origin: Vector3,
	structureOf: StructureLookup?
): { StructureHit }
	if not structureOf then
		return {}
	end
	local best: { [Model]: number } = {}
	for _, part in parts do
		local model = structureOf(part)
		if model then
			local distance = (part.Position - origin).Magnitude
			if best[model] == nil or distance < best[model] then
				best[model] = distance
			end
		end
	end
	local hits: { StructureHit } = {}
	for model, distance in best do
		table.insert(hits, { model = model, distance = distance })
	end
	table.sort(hits, function(a, b)
		return a.distance < b.distance
	end)
	return hits
end

local function trim<T>(list: { T }, max: number?): { T }
	if not max or #list <= max then
		return list
	end
	local trimmed = table.create(max)
	for i = 1, max do
		trimmed[i] = list[i]
	end
	return trimmed
end

local function eyeOrigin(attacker: Model, root: BasePart): Vector3
	local head = attacker:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return root.Position + Vector3.new(0, 1.5, 0)
end

local function hasLineOfSight(origin: Vector3, target: Hit, attacker: Model): boolean
	local result =
		workspace:Raycast(origin, target.root.Position - origin, rayParams({ attacker, target.model }))
	return result == nil
end

---------------------------------------------------------------- lag compensation

local histories: { [Model]: LagHistory.History<Vector3> } = setmetatable({}, { __mode = "k" }) :: any
local historyStarted = false

-- Records every player character's root position SampleRate times a second.
-- CombatService starts it once.
function HitDetection.startHistory()
	if historyStarted or not LAG.Enabled then
		return
	end
	historyStarted = true
	local capacity = math.ceil(LAG.SampleRate * (LAG.MaxRewind + 0.2)) + 2
	local interval = 1 / LAG.SampleRate
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < interval then
			return
		end
		acc = 0
		local t = os.clock()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = HitDetection.getRoot(character)
			if character and root then
				local h = histories[character]
				if not h then
					h = LagHistory.new(capacity)
					histories[character] = h
				end
				LagHistory.push(h, t, root.Position)
			end
		end
	end)
end

local function rewindSeconds(attacker: Model): number
	local player = Players:GetPlayerFromCharacter(attacker)
	if not player then
		return 0
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local seconds = (if ok and type(ping) == "number" then ping else 0) + LAG.InterpolationDelay
	return math.clamp(seconds, 0, LAG.MaxRewind)
end

-- Adds player targets that the server-time hitbox missed but that were inside
-- it (plus Padding) where the attacker saw them. `inside` tests a position.
local function addRewound(hits: { Hit }, attacker: Model, origin: Vector3, inside: (Vector3) -> boolean)
	if not LAG.Enabled or not historyStarted then
		return
	end
	local rewind = rewindSeconds(attacker)
	if rewind <= 0 then
		return
	end
	local seen: { [Model]: boolean } = {}
	for _, hit in hits do
		seen[hit.model] = true
	end
	local at = os.clock() - rewind
	local added = false
	for _, player in Players:GetPlayers() do
		local model = player.Character
		if not model or model == attacker or seen[model] then
			continue
		end
		local h = histories[model]
		local past = h and LagHistory.at(h, at)
		local humanoid = aliveHumanoid(model)
		local root = HitDetection.getRoot(model)
		if not past or not humanoid or not root or not inside(past) then
			continue
		end
		-- Never through walls: the past position must be visible from the attacker.
		local blocked = workspace:Raycast(origin, past - origin, rayParams({ attacker, model }))
		if blocked then
			continue
		end
		table.insert(
			hits,
			{ model = model, humanoid = humanoid, root = root, distance = (past - origin).Magnitude }
		)
		added = true
	end
	if added then
		table.sort(hits, function(a, b)
			return a.distance < b.distance
		end)
	end
end

-- Returns the characters hit and, when structureOf is given, the
-- registered structures hit. maxTargets caps each list separately.
function HitDetection.query(
	attacker: Model,
	action: Actions.Action,
	aim: any,
	structureOf: StructureLookup?
): ({ Hit }, { StructureHit })
	local root = HitDetection.getRoot(attacker)
	if not root then
		return {}, {}
	end
	local hitbox = action.hitbox
	local shape = hitbox.shape
	local hits: { Hit }
	local structures: { StructureHit }

	if shape == "Box" then
		local range = hitbox.range :: number
		local cf = root.CFrame * CFrame.new(0, 0, -range / 2)
		local size = Vector3.new(hitbox.width :: number, hitbox.height :: number, range)
		local parts = workspace:GetPartBoundsInBox(cf, size, overlapParams(attacker))
		hits = collect(parts, root.Position)
		structures = collectStructures(parts, root.Position, structureOf)
		local half = size / 2 + Vector3.one * LAG.Padding
		addRewound(hits, attacker, root.Position, function(position)
			local p = cf:PointToObjectSpace(position)
			return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
		end)
	elseif shape == "Radius" then
		local radius = hitbox.radius :: number
		local parts = workspace:GetPartBoundsInRadius(root.Position, radius, overlapParams(attacker))
		hits = collect(parts, root.Position)
		structures = collectStructures(parts, root.Position, structureOf)
		addRewound(hits, attacker, root.Position, function(position)
			return (position - root.Position).Magnitude <= radius + LAG.Padding
		end)
	elseif shape == "Ray" then
		local origin = eyeOrigin(attacker, root)
		local dir = HitDetection.sanitiseAim(aim, root)
		local result = workspace:Raycast(origin, dir * (hitbox.range :: number), rayParams({ attacker }))
		if not result or not result.Instance:IsA("BasePart") then
			return {}, {}
		end
		local part = result.Instance :: BasePart
		local distance = (result.Position - origin).Magnitude
		hits = collect({ part }, origin)
		if hits[1] then
			hits[1].distance = distance
			structures = {}
		else
			local model = structureOf and structureOf(part)
			structures = if model then { { model = model, distance = distance } } else {}
		end
	elseif shape == "Cone" then
		local origin = eyeOrigin(attacker, root)
		local dir = HitDetection.sanitiseAim(aim, root)
		local range = hitbox.range :: number
		local halfAngle = math.rad((hitbox.angle :: number) / 2)
		local function inCone(position: Vector3): boolean
			local offset = position - origin
			if offset.Magnitude > range then
				return false
			end
			local angle = if offset.Magnitude < 1e-3
				then 0
				else math.acos(math.clamp(offset.Unit:Dot(dir), -1, 1))
			return angle <= halfAngle
		end
		local parts = workspace:GetPartBoundsInRadius(origin, range, overlapParams(attacker))
		hits = {}
		for _, hit in collect(parts, origin) do
			if inCone(hit.root.Position) and hasLineOfSight(origin, hit, attacker) then
				table.insert(hits, hit)
			end
		end
		local coneParts = {}
		for _, part in parts do
			if inCone(part.Position) then
				table.insert(coneParts, part)
			end
		end
		structures = collectStructures(coneParts, origin, structureOf)
	else
		return {}, {}
	end

	return trim(hits, action.maxTargets), trim(structures, action.maxTargets)
end

return HitDetection
