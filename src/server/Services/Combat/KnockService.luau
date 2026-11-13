--!strict
--[[
	KnockService: downed state, carrying and executions (GDD §6.7).

	A player character whose health reaches Knock.HealthLimit is downed
	instead of dying: it ragdolls, can't act, and gets up after Knock.Duration.
	Nearby players can carry it (V) or execute it (B, takes GripDuration and
	is interrupted if the executioner is hit). An execution is the only way a
	downed character dies; the death then goes to moderator review like any
	other (§3.4), credited to the executioner.

	Rules are in Shared.Combat.KnockCore. This service wires them to
	humanoids. NPC rigs opt in with the CollectionService tag "Knockable" or
	KnockService:Track(model) (wildlife or test dummies that should be downed).

	Attributes set for other systems and clients:
	  character.Knocked    "Down" | "Carried" | "Gripped" | nil
	  player.KnockAction   "Carrying" | "Executing" | nil

	Public API
	  KnockService:IsKnocked(model) -> boolean
	  KnockService:IsBusy(player) -> boolean      -- carrying or executing
	  KnockService:Track(model)                   -- NPCs
	  KnockService.Knocked   Signal(model)
	  KnockService.Recovered Signal(model)
	  KnockService.Executed  Signal(model, executioner: Player)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KNOCKABLE_TAG = "Knockable"

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Loader = require(Shared.Loader)
local KnockCore = require(Shared.Combat.KnockCore)
local CombatSettings = require(Shared.Combat.Config.CombatSettings)

local StatusEffects = require(script.Parent.StatusEffects)

local SETTINGS: KnockCore.Settings = CombatSettings.Knock :: any

local KnockService = {}
KnockService.Knocked = Signal.new()
KnockService.Recovered = Signal.new()
KnockService.Executed = Signal.new()

type Entry = {
	model: Model,
	humanoid: Humanoid,
	state: KnockCore.State?,
	executing: boolean, -- set while an execution is lowering health to 0
	connections: { RBXScriptConnection },
}

type Action = {
	kind: "Carrying" | "Executing",
	target: Entry,
	weld: WeldConstraint?,
	connection: RBXScriptConnection?,
}

local entries: { [Model]: Entry } = {}
local actions: { [Player]: Action } = {}

local CombatService: any = nil

local function now(): number
	return os.clock()
end

local function rootOf(model: Model?): BasePart?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function setMode(entry: Entry)
	local state = entry.state
	entry.model:SetAttribute("Knocked", if state then state.mode else nil)
	-- Server time the character gets up, for HUDs (only while the timer runs).
	entry.model:SetAttribute(
		"KnockRecoverAt",
		if state and state.mode == "Down"
			then workspace:GetServerTimeNow() + KnockCore.timeLeft(state, now())
			else nil
	)
end

local function setAction(player: Player, kind: string?)
	player:SetAttribute("KnockAction", kind)
end

local function allowDeath(humanoid: Humanoid, allowed: boolean)
	humanoid.BreakJointsOnDeath = allowed
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, allowed)
end

---------------------------------------------------------------- carry / grip

local function endAction(player: Player)
	local action = actions[player]
	if not action then
		return
	end
	actions[player] = nil
	setAction(player, nil)
	if action.connection then
		action.connection:Disconnect()
	end
	local target = action.target
	local state = target.state
	if action.kind == "Carrying" then
		if action.weld then
			action.weld:Destroy()
		end
		for _, part in target.model:GetDescendants() do
			if part:IsA("BasePart") then
				local massless = part:GetAttribute("PreCarryMassless")
				if massless ~= nil then
					part.Massless = massless
					part:SetAttribute("PreCarryMassless", nil)
				end
			end
		end
		local root = rootOf(target.model)
		local targetPlayer = Players:GetPlayerFromCharacter(target.model)
		if root and root.Parent then
			pcall(function()
				root:SetNetworkOwner(targetPlayer)
			end)
		end
		if state then
			KnockCore.stopCarry(SETTINGS, state, now())
		end
	else
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			StatusEffects.clear(humanoid)
		end
		if state then
			KnockCore.cancelGrip(SETTINGS, state, now())
		end
	end
	setMode(target)
end

-- Ends the action if the actor takes damage.
local function interruptOnDamage(player: Player, humanoid: Humanoid): RBXScriptConnection
	local last = humanoid.Health
	return humanoid.HealthChanged:Connect(function(health)
		if health < last then
			endAction(player)
		end
		last = health
	end)
end

local function findTarget(player: Player): Entry?
	local root = rootOf(player.Character)
	if not root then
		return nil
	end
	local list: { Entry } = {}
	local candidates = {}
	for model, entry in entries do
		if model ~= player.Character and entry.state then
			local other = rootOf(model)
			if other then
				table.insert(list, entry)
				table.insert(
					candidates,
					{ distance = (other.Position - root.Position).Magnitude, state = entry.state }
				)
			end
		end
	end
	local index = KnockCore.pickTarget(SETTINGS, now(), candidates)
	return if index then list[index] else nil
end

local function canAct(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = rootOf(character)
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil, nil
	end
	if character and character:GetAttribute("Knocked") then
		return nil, nil
	end
	if StatusEffects.isStunned(humanoid) then
		return nil, nil
	end
	return humanoid, root
end

local function carry(player: Player)
	if actions[player] then
		if actions[player].kind == "Carrying" then
			endAction(player)
		end
		return
	end
	local humanoid, root = canAct(player)
	if not humanoid or not root then
		return
	end
	local target = findTarget(player)
	local targetRoot = target and rootOf(target.model)
	if not target or not target.state or not targetRoot then
		return
	end
	local ok = KnockCore.startCarry(target.state, now(), player.UserId)
	if not ok then
		return
	end
	setMode(target)
	for _, part in target.model:GetDescendants() do
		if part:IsA("BasePart") then
			part:SetAttribute("PreCarryMassless", part.Massless)
			part.Massless = true
		end
	end
	targetRoot.CFrame = root.CFrame * CFrame.new(-1.5, 1.2, 0) * CFrame.Angles(math.rad(270), 0, 0)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = targetRoot
	weld.Parent = root
	-- The carrier simulates the carried body so it moves with them smoothly.
	pcall(function()
		targetRoot:SetNetworkOwner(player)
	end)
	actions[player] = {
		kind = "Carrying",
		target = target,
		weld = weld,
		connection = interruptOnDamage(player, humanoid),
	}
	setAction(player, "Carrying")
end

local function execute(target: Entry, executioner: Player)
	target.state = nil
	target.executing = true
	setMode(target)
	allowDeath(target.humanoid, true)
	if CombatService then
		CombatService:RecordHit(target.humanoid, executioner, "Execute")
	end
	KnockService.Executed:Fire(target.model, executioner)
	target.humanoid.Health = 0
end

local function grip(player: Player)
	if actions[player] then
		if actions[player].kind == "Executing" then
			endAction(player)
		end
		return
	end
	local humanoid, root = canAct(player)
	if not humanoid or not root then
		return
	end
	local target = findTarget(player)
	local targetRoot = target and rootOf(target.model)
	if not target or not target.state or not targetRoot then
		return
	end
	local ok = KnockCore.startGrip(SETTINGS, target.state, now(), player.UserId)
	if not ok then
		return
	end
	setMode(target)
	-- Hold the executioner in place for the grip.
	StatusEffects.root(humanoid, SETTINGS.GripDuration)
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 1e-3 then
		targetRoot.CFrame = CFrame.new(root.Position + flat.Unit * 2.5)
	end
	actions[player] = {
		kind = "Executing",
		target = target,
		connection = interruptOnDamage(player, humanoid),
	}
	setAction(player, "Executing")
	Net.FireAll("KnockExecutionStarted", player.Character, target.model)
end

---------------------------------------------------------------- tracking

local function recover(entry: Entry)
	entry.state = nil
	setMode(entry)
	KnockService.Recovered:Fire(entry.model)
end

local function knock(entry: Entry)
	entry.state = KnockCore.knock(SETTINGS, now())
	setMode(entry)
	-- A downed player drops whatever they were doing.
	local player = Players:GetPlayerFromCharacter(entry.model)
	if player then
		endAction(player)
	end
	KnockService.Knocked:Fire(entry.model)
end

local function untrack(model: Model)
	local entry = entries[model]
	if not entry then
		return
	end
	entries[model] = nil
	for _, c in entry.connections do
		c:Disconnect()
	end
	for player, action in actions do
		if action.target == entry then
			endAction(player)
		end
	end
end

function KnockService:Track(model: Model)
	if entries[model] then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local entry: Entry =
		{ model = model, humanoid = humanoid, state = nil, executing = false, connections = {} }
	entries[model] = entry
	allowDeath(humanoid, false)
	local last = humanoid.Health
	table.insert(
		entry.connections,
		humanoid.HealthChanged:Connect(function(health)
			if entry.executing then
				return
			end
			local damaged = health < last
			if entry.state then
				if damaged then
					KnockCore.onDamaged(SETTINGS, entry.state, now())
					setMode(entry)
				end
				if health < SETTINGS.HealthLimit then
					humanoid.Health = SETTINGS.HealthLimit
					health = SETTINGS.HealthLimit
				end
			elseif health <= SETTINGS.HealthLimit and damaged then
				humanoid.Health = SETTINGS.HealthLimit
				health = SETTINGS.HealthLimit
				knock(entry)
			end
			last = health
		end)
	)
	table.insert(
		entry.connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				untrack(model)
			end
		end)
	)
end

function KnockService:IsKnocked(model: Model): boolean
	local entry = entries[model]
	return entry ~= nil and entry.state ~= nil
end

function KnockService:IsBusy(player: Player): boolean
	return actions[player] ~= nil
end

---------------------------------------------------------------- lifecycle

function KnockService:Init()
	Net.OnEvent("KnockCarry", carry, { rateLimit = CombatSettings.Knock.RateLimit })
	Net.OnEvent("KnockExecute", grip, { rateLimit = CombatSettings.Knock.RateLimit })
end

function KnockService:Start()
	local ok, combat = pcall(Loader.Get, "CombatService")
	if ok then
		CombatService = combat
	end

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			endAction(player)
			KnockService:Track(character)
		end)
		if player.Character then
			KnockService:Track(player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	-- NPC rigs tagged "Knockable" (CollectionService) are downed like players.
	local function onTagged(instance: Instance)
		if instance:IsA("Model") then
			KnockService:Track(instance)
		end
	end
	CollectionService:GetInstanceAddedSignal(KNOCKABLE_TAG):Connect(onTagged)
	for _, instance in CollectionService:GetTagged(KNOCKABLE_TAG) do
		onTagged(instance)
	end
	Players.PlayerRemoving:Connect(function(player)
		endAction(player)
		if player.Character then
			untrack(player.Character)
		end
	end)

	-- Timers: recoveries and finished executions.
	while true do
		task.wait(0.1)
		local t = now()
		for _, entry in entries do
			local state = entry.state
			if not state then
				continue
			end
			if KnockCore.shouldRecover(state, t) then
				recover(entry)
			elseif KnockCore.gripFinished(state, t) then
				local executioner: Player? = nil
				for player, action in actions do
					if action.target == entry and action.kind == "Executing" then
						executioner = player
					end
				end
				if executioner then
					local action = actions[executioner]
					if action and action.connection then
						action.connection:Disconnect()
					end
					actions[executioner] = nil
					setAction(executioner, nil)
					local humanoid = executioner.Character
						and executioner.Character:FindFirstChildOfClass("Humanoid")
					if humanoid then
						StatusEffects.clear(humanoid)
					end
					execute(entry, executioner)
				else
					KnockCore.cancelGrip(SETTINGS, state, t)
					setMode(entry)
				end
			end
		end
	end
end

return KnockService
