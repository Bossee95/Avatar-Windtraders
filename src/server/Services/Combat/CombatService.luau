--!strict
--[[
	CombatService: server authority for weapons, kits, abilities and hits
	(GDD §5, §6, §16.5).

	What it enforces on every request:
	  * the active character is alive and holds a kit for the weapon type
	    (character.kits[weaponType], granted only by the Loreteam)
	  * the variation exists and the character owns it (inventory provider)
	  * one weapon at a time: equipping replaces the current weapon
	  * no weapon / G ability switching while combat tagged, mid-action,
	    stunned or dead (CombatSettings.SwitchBlockedWhen, §19.5)
	  * G abilities are assigned to the character (character.abilities)
	  * cooldowns, action lockout (windup + recovery) and M1 combo pacing
	  * hitboxes are computed on the server from server positions

	Permissions are re-read from the character record on every action, so a
	Loreteam revoke takes effect on the next input. Revalidate(player) also
	unequips straight away when a kit or weapon item is lost.

	Public API (colon calls, as with every service):
	  CombatService:Equip(player, variationId) -> (ok, err?)
	  CombatService:Unequip(player) -> (ok, err?)
	  CombatService:SelectGAbility(player, abilityId?) -> (ok, err?)
	  CombatService:GetEquipped(player) -> { variationId, weaponType }?
	  CombatService:IsInCombat(player) -> boolean
	  CombatService:TagCombat(player)               -- e.g. from other damage sources
	  CombatService:Revalidate(player)              -- after kits/items change
	  CombatService:SetVariationOwnershipProvider(fn(player, variationId) -> boolean)
	  CombatService:SetTargetFilter(fn(attacker: Player, targetModel: Model) -> boolean)
	  CombatService:SetDamageHandler(fn(attacker: Player, humanoid, amount, actionId))
	  CombatService.CombatTagChanged  Signal(player, isTagged)
	  CombatService.ActionPerformed   Signal(player, actionId, targets: { Model })
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Loader = require(Shared.Loader)

local CombatShared = Shared.Combat
local CombatRules = require(CombatShared.CombatRules)
local ConfigValidator = require(CombatShared.ConfigValidator)
local Actions = require(CombatShared.Config.Actions)
local Kits = require(CombatShared.Config.Kits)
local Variations = require(CombatShared.Config.Variations)
local WeaponTypes = require(CombatShared.Config.WeaponTypes)
local GAbilities = require(CombatShared.Config.GAbilities)
local CombatSettings = require(CombatShared.Config.CombatSettings)

local CombatTag = require(script.Parent.CombatTag)
local Cooldowns = require(script.Parent.Cooldowns)
local HitDetection = require(script.Parent.HitDetection)
local StatusEffects = require(script.Parent.StatusEffects)

type PlayerState = {
	variationId: string?,
	gAbilityId: string?,
	comboIndex: number?,
	lastM1End: number?,
	busyUntil: number,
	token: number,
	buffMultiplier: number,
	buffUntil: number,
	weaponPart: BasePart?,
}

local CombatService = {}

CombatService.CombatTagChanged = Signal.new()
CombatService.ActionPerformed = Signal.new()

local states: { [Player]: PlayerState } = {}
local tags = CombatTag.new(CombatSettings.CombatTagDuration)
local cooldowns = Cooldowns.new()
local enabled = false

local ownershipProvider: ((Player, string) -> boolean)? = nil
local targetFilter: ((Player, Model) -> boolean)? = nil
local damageHandler: ((Player, Humanoid, number, string) -> ())? = nil

local CharacterService: any = nil
local DeathReviewService: any = nil

-- Who last hit each player's humanoid, for death reports.
local KILL_CREDIT_WINDOW = 10
local lastHitBy: { [Humanoid]: { userId: number, actionId: string, at: number } } = setmetatable({}, { __mode = "k" }) :: any

local IS_STUDIO = RunService:IsStudio()

---------------------------------------------------------------- helpers

local function studioGrantAll(): boolean
	return IS_STUDIO and CombatSettings.StudioGrantAll
end

local STUDIO_RECORD: CombatRules.Record = (function()
	local kits = {}
	for weaponType, levels in Kits do
		local top = 0
		for level in levels do
			top = math.max(top, level)
		end
		kits[weaponType] = { level = top }
	end
	local abilities = {}
	for id in GAbilities do
		abilities[id] = { source = "Studio" }
	end
	return { kits = kits, abilities = abilities }
end)()

-- The record permissions are read from. Returns nil if the player has no
-- living active character (they are on the character screen or dead).
local function getRecord(player: Player): CombatRules.Record?
	if studioGrantAll() then
		return STUDIO_RECORD
	end
	if not CharacterService then
		return nil
	end
	local character = CharacterService:GetActiveCharacter(player)
	if not character or character.status ~= "Alive" then
		return nil
	end
	return character
end

local function ownsVariation(player: Player, variationId: string): boolean
	if ownershipProvider then
		local ok, result = pcall(ownershipProvider, player, variationId)
		if not ok then
			warn("[CombatService] ownership provider errored:", result)
			return false
		end
		return result == true
	end
	-- No inventory system registered yet: only Studio may equip freely.
	return studioGrantAll()
end

local function getState(player: Player): PlayerState
	local state = states[player]
	if not state then
		state = {
			busyUntil = 0,
			token = 0,
			buffMultiplier = 1,
			buffUntil = 0,
		}
		states[player] = state
	end
	return state
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function rulesState(player: Player): CombatRules.State
	local state = getState(player)
	local humanoid = getHumanoid(player)
	return {
		combatTagged = tags:isTagged(player),
		busy = os.clock() < state.busyUntil,
		stunned = StatusEffects.isStunned(humanoid),
		dead = humanoid == nil or humanoid.Health <= 0,
	}
end

local function pushState(player: Player)
	local state = getState(player)
	player:SetAttribute("CombatWeapon", state.variationId)
	player:SetAttribute("CombatGAbility", state.gAbilityId)
	player:SetAttribute("InCombat", tags:isTagged(player) or nil)
	Net.Fire("CombatState", player, {
		variationId = state.variationId,
		gAbilityId = state.gAbilityId,
		inCombat = tags:isTagged(player),
		combatTagRemaining = tags:remaining(player),
		cooldowns = cooldowns:snapshot(player),
	})
end

local function setTag(player: Player)
	if tags:tag(player) then
		CombatService.CombatTagChanged:Fire(player, true)
	end
	player:SetAttribute("InCombat", true)
end

local function clearTag(player: Player)
	if tags:clear(player) then
		CombatService.CombatTagChanged:Fire(player, false)
	end
	player:SetAttribute("InCombat", nil)
end

-- Placeholder weapon model: a coloured part welded to the right hand.
local function attachWeaponModel(player: Player, state: PlayerState)
	if state.weaponPart then
		state.weaponPart:Destroy()
		state.weaponPart = nil
	end
	local variation = state.variationId and Variations[state.variationId]
	local character = player.Character
	if not variation or not character then
		return
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end
	local model = WeaponTypes[variation.weaponType].placeholderModel
	local part = Instance.new("Part")
	part.Name = "EquippedWeapon"
	part.Size = Vector3.new(model.size[1], model.size[2], model.size[3])
	part.Color = Color3.fromRGB(model.color[1], model.color[2], model.color[3])
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CFrame = hand.CFrame * CFrame.new(0, -hand.Size.Y / 2, -model.size[3] / 2 + 0.5)
	part:SetAttribute("VariationId", state.variationId)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = part
	weld.Parent = part
	part.Parent = character
	state.weaponPart = part
end

local function resetActionState(state: PlayerState)
	state.token += 1
	state.comboIndex = nil
	state.lastM1End = nil
	state.busyUntil = 0
end

local function forceUnequip(player: Player, reason: string)
	local state = getState(player)
	if not state.variationId then
		return
	end
	state.variationId = nil
	resetActionState(state)
	attachWeaponModel(player, state)
	pushState(player)
	Net.Fire("CombatNotice", player, "Unequipped", reason)
end

---------------------------------------------------------------- effects

local function getEffectsFolder(): Folder
	local folder = workspace:FindFirstChild("CombatEffects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CombatEffects"
		folder.Parent = workspace
	end
	return folder :: Folder
end

local function applyKnockback(attackerRoot: BasePart, hit: HitDetection.Hit, force: number)
	local offset = hit.root.Position - attackerRoot.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else attackerRoot.CFrame.LookVector
	local velocity = dir * force + Vector3.new(0, force * 0.3, 0)
	local targetPlayer = Players:GetPlayerFromCharacter(hit.model)
	if targetPlayer then
		-- Player characters are simulated by their own client.
		Net.Fire("CombatKnockback", targetPlayer, velocity)
	else
		hit.root.AssemblyLinearVelocity = velocity
	end
end

local function applySelfEffects(player: Player, state: PlayerState, action: Actions.Action)
	local character = player.Character
	local humanoid = getHumanoid(player)
	local root = HitDetection.getRoot(character)
	for _, effect in action.selfEffects or {} do
		if effect.type == "SelfBuff" then
			state.buffMultiplier = effect.damageMultiplier or 1
			state.buffUntil = os.clock() + (effect.duration or 0)
		elseif effect.type == "SelfRoot" then
			if humanoid then
				StatusEffects.root(humanoid, effect.duration or 0)
			end
		elseif effect.type == "Smoke" and root then
			local distance = effect.distance or 0
			local radius = effect.radius or 10
			local cloud = Instance.new("Part")
			cloud.Name = "SmokeCloud"
			cloud.Shape = Enum.PartType.Ball
			cloud.Size = Vector3.one * radius * 2
			cloud.Position = root.Position + root.CFrame.LookVector * distance
			cloud.Anchored = true
			cloud.CanCollide = false
			cloud.CanQuery = false
			cloud.CanTouch = false
			cloud.Color = Color3.fromRGB(200, 200, 200)
			cloud.Material = Enum.Material.SmoothPlastic
			cloud.Transparency = 0.15
			cloud.CastShadow = false
			cloud.Parent = getEffectsFolder()
			Debris:AddItem(cloud, effect.duration or 10)
		end
	end
end

local function damageMultiplier(state: PlayerState): number
	if os.clock() < state.buffUntil then
		return state.buffMultiplier
	end
	return 1
end

local function performHit(player: Player, state: PlayerState, actionId: string, action: Actions.Action, aim: any): { Model }
	local character = player.Character
	local attackerRoot = HitDetection.getRoot(character)
	if not character or not attackerRoot then
		return {}
	end
	local hitModels = {}
	for _, hit in HitDetection.query(character, action, aim) do
		if targetFilter then
			local ok, allowed = pcall(targetFilter, player, hit.model)
			if not ok or not allowed then
				continue
			end
		end
		local amount = (action.damage or 0) * damageMultiplier(state) * CombatRules.falloffMultiplier(action, hit.distance)
		if amount > 0 then
			if damageHandler then
				local ok, err = pcall(damageHandler, player, hit.humanoid, amount, actionId)
				if not ok then
					warn("[CombatService] damage handler errored:", err)
				end
			else
				hit.humanoid:TakeDamage(amount)
			end
		end
		for _, effect in action.effects or {} do
			if effect.type == "Knockback" then
				applyKnockback(attackerRoot, hit, effect.force or 0)
			elseif effect.type == "Stun" then
				StatusEffects.stun(hit.humanoid, effect.duration or 0)
			end
		end
		setTag(player)
		local targetPlayer = Players:GetPlayerFromCharacter(hit.model)
		if targetPlayer then
			setTag(targetPlayer)
			lastHitBy[hit.humanoid] = { userId = player.UserId, actionId = actionId, at = os.clock() }
			-- A stun interrupts the target's windup.
			if StatusEffects.isStunned(hit.humanoid) and states[targetPlayer] then
				states[targetPlayer].token += 1
			end
		end
		table.insert(hitModels, hit.model)
	end
	if #hitModels > 0 then
		Net.FireAll("CombatHit", character, actionId, hitModels)
	end
	return hitModels
end

---------------------------------------------------------------- requests

local function useAction(player: Player, input: string, aim: any)
	if not enabled then
		return
	end
	local record = getRecord(player)
	if not record then
		return
	end
	local character = player.Character
	local humanoid = getHumanoid(player)
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	if StatusEffects.isStunned(humanoid) then
		return
	end

	local state = getState(player)
	local now = os.clock()
	if now + CombatSettings.InputLeniency < state.busyUntil then
		return
	end

	local comboIndex: number? = nil
	local weaponType: string? = nil
	if state.variationId then
		weaponType = Variations[state.variationId].weaponType
	end
	if input == "M1" and weaponType then
		comboIndex = CombatRules.nextComboIndex(weaponType, state.comboIndex, state.lastM1End, now)
	end

	local actionId, reason = CombatRules.resolveAction(record, {
		variationId = state.variationId,
		gAbilityId = state.gAbilityId,
	}, input, comboIndex)
	if not actionId then
		Net.Fire("CombatNotice", player, "ActionRejected", reason)
		return
	end
	local action = Actions[actionId]

	local ready, left = cooldowns:isReady(player, actionId)
	if not ready then
		Net.Fire("CombatNotice", player, "OnCooldown", actionId, left)
		return
	end

	-- Commit.
	local startAt = math.max(now, state.busyUntil)
	local duration = CombatRules.actionDuration(action)
	state.busyUntil = startAt + duration
	if input == "M1" and weaponType and comboIndex then
		state.comboIndex = comboIndex
		local isLast = comboIndex >= #WeaponTypes[weaponType].m1Combo
		state.lastM1End = state.busyUntil
		if isLast then
			state.busyUntil += WeaponTypes[weaponType].comboEndlag
		end
	end
	cooldowns:start(player, actionId, action.cooldown)
	state.token += 1
	local token = state.token

	Net.FireAll("CombatActionStarted", character, actionId, input)
	if action.cooldown > 0 then
		Net.Fire("CombatState", player, {
			variationId = state.variationId,
			gAbilityId = state.gAbilityId,
			inCombat = tags:isTagged(player),
			combatTagRemaining = tags:remaining(player),
			cooldowns = cooldowns:snapshot(player),
		})
	end

	task.spawn(function()
		local delayUntilStart = startAt - os.clock()
		if delayUntilStart > 0 then
			task.wait(delayUntilStart)
		end
		task.wait(action.windup)
		local function stillValid(): boolean
			return state.token == token
				and player.Parent ~= nil
				and player.Character == character
				and humanoid.Health > 0
				and not StatusEffects.isStunned(humanoid)
		end
		if not stillValid() then
			return
		end
		applySelfEffects(player, state, action)
		local allTargets: { Model } = {}
		local hits = action.hits or 1
		for i = 1, hits do
			if i > 1 then
				task.wait(action.hitInterval or 0)
				if not stillValid() then
					break
				end
			end
			for _, model in performHit(player, state, actionId, action, aim) do
				table.insert(allTargets, model)
			end
		end
		CombatService.ActionPerformed:Fire(player, actionId, allTargets)
	end)
end

---------------------------------------------------------------- public API

function CombatService:Equip(player: Player, variationId: any): (boolean, string?)
	if not enabled then
		return false, "CombatDisabled"
	end
	local record = getRecord(player)
	if not record then
		return false, "NoCharacter"
	end
	local state = getState(player)
	local owns = type(variationId) == "string" and Variations[variationId] ~= nil and ownsVariation(player, variationId)
	local ok, err = CombatRules.canEquip(record, variationId, owns, rulesState(player), state.variationId)
	if not ok then
		return false, err
	end
	state.variationId = variationId
	resetActionState(state)
	attachWeaponModel(player, state)
	pushState(player)
	return true, nil
end

function CombatService:Unequip(player: Player): (boolean, string?)
	local state = getState(player)
	if not state.variationId then
		return true, nil
	end
	local ok, err = CombatRules.canUnequip(rulesState(player))
	if not ok then
		return false, err
	end
	state.variationId = nil
	resetActionState(state)
	attachWeaponModel(player, state)
	pushState(player)
	return true, nil
end

function CombatService:SelectGAbility(player: Player, abilityId: any): (boolean, string?)
	local record = getRecord(player)
	if not record then
		return false, "NoCharacter"
	end
	local ok, err = CombatRules.canSelectGAbility(record, abilityId, rulesState(player))
	if not ok then
		return false, err
	end
	getState(player).gAbilityId = abilityId
	pushState(player)
	return true, nil
end

function CombatService:GetEquipped(player: Player): { variationId: string, weaponType: string }?
	local state = states[player]
	if not state or not state.variationId then
		return nil
	end
	return { variationId = state.variationId, weaponType = Variations[state.variationId].weaponType }
end

function CombatService:IsInCombat(player: Player): boolean
	return tags:isTagged(player)
end

function CombatService:TagCombat(player: Player)
	setTag(player)
end

-- Re-checks the equipped weapon and G ability against the current
-- character record and inventory. Call after a kit or ability is revoked or
-- a weapon item leaves the character. Revocations apply even in combat.
function CombatService:Revalidate(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local record = getRecord(player)
	if state.variationId then
		local variation = Variations[state.variationId]
		if not record then
			forceUnequip(player, "NoCharacter")
		elseif not CombatRules.getKitLevel(record, variation.weaponType) then
			forceUnequip(player, "KitNotAssigned")
		elseif not ownsVariation(player, state.variationId) then
			forceUnequip(player, "NotOwned")
		end
	end
	if state.gAbilityId and not CombatRules.hasGAbility(record, state.gAbilityId) then
		state.gAbilityId = nil
		pushState(player)
		Net.Fire("CombatNotice", player, "GAbilityCleared", "AbilityNotAssigned")
	end
end

function CombatService:SetVariationOwnershipProvider(fn: (Player, string) -> boolean)
	ownershipProvider = fn
	for player in states do
		CombatService:Revalidate(player)
	end
end

function CombatService:SetTargetFilter(fn: (Player, Model) -> boolean)
	targetFilter = fn
end

function CombatService:SetDamageHandler(fn: (Player, Humanoid, number, string) -> ())
	damageHandler = fn
end

-- Clears everything tied to the current character (new character
-- selected, permanent death, leaving).
local function resetPlayer(player: Player)
	local state = states[player]
	if state then
		state.variationId = nil
		state.gAbilityId = nil
		state.buffUntil = 0
		resetActionState(state)
		attachWeaponModel(player, state)
	end
	cooldowns:clear(player)
	clearTag(player)
	if player.Parent then
		pushState(player)
	end
end

---------------------------------------------------------------- lifecycle

function CombatService:Init()
	local problems = ConfigValidator.validate()
	if #problems > 0 then
		warn("[CombatService] combat config is invalid, combat is disabled:\n  " .. table.concat(problems, "\n  "))
		enabled = false
	else
		enabled = true
	end
	if studioGrantAll() then
		warn("[CombatService] Studio: every kit, variation and G ability is granted (CombatSettings.StudioGrantAll)")
	end

	local function isString(v: any)
		return type(v) == "string"
	end

	Net.OnEvent("CombatUseAction", useAction, {
		rateLimit = CombatSettings.ActionRateLimit,
		validate = function(input, aim)
			return CombatRules.isInput(input) and (aim == nil or typeof(aim) == "Vector3")
		end,
	})
	Net.OnInvoke("CombatEquip", function(player, variationId)
		return CombatService:Equip(player, variationId)
	end, { rateLimit = CombatSettings.EquipRateLimit, validate = isString })
	Net.OnInvoke("CombatUnequip", function(player)
		return CombatService:Unequip(player)
	end, { rateLimit = CombatSettings.EquipRateLimit })
	Net.OnInvoke("CombatSelectGAbility", function(player, abilityId)
		return CombatService:SelectGAbility(player, abilityId)
	end, {
		rateLimit = CombatSettings.EquipRateLimit,
		validate = function(abilityId)
			return abilityId == nil or isString(abilityId)
		end,
	})
end

function CombatService:Start()
	local ok, service = pcall(Loader.Get, "CharacterService")
	if ok and service then
		CharacterService = service
		service:RegisterSwitchGuard("Combat", function(player: Player)
			if tags:isTagged(player) then
				return false, "InCombat"
			end
			return true
		end)
		service.CharacterSelected:Connect(function(player: Player)
			resetPlayer(player)
		end)
		service.CharacterChanged:Connect(function(player: Player?, _userId, _characterId, field: string)
			if player and (field == "Kits" or field == "Abilities" or field == "Status") then
				CombatService:Revalidate(player)
			end
		end)
	else
		warn("[CombatService] CharacterService not found; only Studio grant-all will allow combat")
	end

	local okPd, permadeath = pcall(Loader.Get, "PermadeathService")
	if okPd and permadeath then
		permadeath.Permadeath:Connect(function(player: Player?)
			if player then
				resetPlayer(player)
			end
		end)
	end

	local okReview, review = pcall(Loader.Get, "DeathReviewService")
	if okReview and review then
		DeathReviewService = review
	end

	-- Every avatar death of a living character is reported for moderator
	-- review (GDD §3.4). The review service ignores deaths outside an active
	-- PD; only a moderator confirmation makes a death permanent.
	local function onDied(player: Player, humanoid: Humanoid)
		local credit = lastHitBy[humanoid]
		lastHitBy[humanoid] = nil
		clearTag(player)
		if not DeathReviewService or not CharacterService then
			return
		end
		local character = CharacterService:GetActiveCharacter(player)
		if not character or character.status ~= "Alive" then
			return
		end
		local recent = credit and os.clock() - credit.at <= KILL_CREDIT_WINDOW
		local root = HitDetection.getRoot(player.Character)
		local reported, err = pcall(function()
			DeathReviewService:ReportDeath({
				userId = player.UserId,
				characterId = character.id,
				killerUserId = if recent then credit.userId else nil,
				occurredAt = os.time(),
				cause = if recent then "Combat:" .. credit.actionId else "Environment",
				location = root and root.CFrame,
			})
		end)
		if not reported then
			warn("[CombatService] ReportDeath failed:", err)
		end
	end

	local function onPlayer(player: Player)
		getState(player)
		local function onCharacter(avatar: Model)
			local state = getState(player)
			resetActionState(state)
			-- The weapon stays equipped across respawns; re-attach the model.
			task.defer(attachWeaponModel, player, state)
			CombatService:Revalidate(player)
			local humanoid = avatar:WaitForChild("Humanoid", 10)
			if humanoid and humanoid:IsA("Humanoid") then
				humanoid.Died:Once(function()
					onDied(player, humanoid)
				end)
			end
		end
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			task.spawn(onCharacter, player.Character)
		end
		player.CharacterRemoving:Connect(function()
			local state = states[player]
			if state then
				resetActionState(state)
				state.weaponPart = nil
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		cooldowns:clear(player)
		if tags:clear(player) then
			CombatService.CombatTagChanged:Fire(player, false)
		end
		states[player] = nil
	end)

	-- Expire combat tags.
	while true do
		task.wait(0.25)
		for _, player in tags:collectExpired() do
			if typeof(player) == "Instance" and player.Parent then
				(player :: Player):SetAttribute("InCombat", nil)
				CombatService.CombatTagChanged:Fire(player, false)
				pushState(player :: Player)
			end
		end
	end
end

return CombatService
