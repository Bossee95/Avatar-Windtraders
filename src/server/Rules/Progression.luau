--!strict
--[[
	Progression rules: pure functions that change a character record.

	Nothing here checks staff permissions (the staff tools do that) and nothing
	is ever granted automatically (GDD §4.4). These functions only keep the
	records valid: the character must be alive, Trials must be approved in
	order, and values must be well-formed.

	Each mutator returns (ok, err) and, on success, appends to character.log.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local Progression = {}

-- Optional catalog checks registered by the systems that own the catalogs
-- (combat owns weapon types and G abilities). Without one, any well-formed
-- id is accepted.
local validators: { [string]: (string) -> boolean } = {}

-- kind: "WeaponType" | "Ability"
function Progression.setValidator(kind: string, fn: ((string) -> boolean)?)
	assert(kind == "WeaponType" or kind == "Ability", "Unknown validator kind: " .. tostring(kind))
	validators[kind] = fn
end

local function passes(kind: string, id: string): boolean
	local validator = validators[kind]
	if not validator then
		return true
	end
	local ok, result = pcall(validator, id)
	return ok and result == true
end

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 64
end

local function isWholeNumber(value: any, min: number): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= min and value <= 1000
end

function Progression.appendLog(character: any, actor: number, action: string, details: { [string]: any }?, now: number)
	table.insert(character.log, { at = now, actor = actor, action = action, details = details })
	local limit = GameConfig.Characters.ProgressionLogLimit
	while #character.log > limit do
		table.remove(character.log, 1)
	end
end

local function requireAlive(character: any): (boolean, string?)
	if character == nil then
		return false, "CharacterNotFound"
	end
	if character.status ~= "Alive" then
		return false, "CharacterDead"
	end
	return true, nil
end

function Progression.setFaction(character: any, faction: any, role: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if not WorldConfig.isValidFaction(faction) then
		return false, "InvalidFaction"
	end
	if role == nil then
		role = WorldConfig.Factions[faction].defaultRole
	end
	if not WorldConfig.isValidRole(faction, role) then
		return false, "InvalidRole"
	end
	local previous = { faction = character.faction, role = character.role }
	character.faction = faction
	character.role = role
	Progression.appendLog(character, actor, "SetFaction", { from = previous, faction = faction, role = role }, now)
	return true, nil
end

function Progression.setRank(character: any, rank: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if not isWholeNumber(rank, 0) then
		return false, "InvalidRank"
	end
	local previous = character.rank
	character.rank = rank
	Progression.appendLog(character, actor, "SetRank", { from = previous, to = rank }, now)
	return true, nil
end

-- The next Trial this character must complete, or nil when the faction has no
-- configured order or every Trial is done.
function Progression.getNextTrial(character: any): string?
	local faction = WorldConfig.Factions[character.faction]
	if not faction then
		return nil
	end
	return faction.trials[#character.trials + 1]
end

local function hasTrial(character: any, trialId: string): number?
	for index, entry in character.trials do
		if entry.id == trialId then
			return index
		end
	end
	return nil
end

function Progression.approveTrial(character: any, trialId: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if not isNonEmptyString(trialId) then
		return false, "InvalidTrial"
	end
	if hasTrial(character, trialId) then
		return false, "AlreadyCompleted"
	end
	local order = WorldConfig.Factions[character.faction].trials
	if #order > 0 then
		if not table.find(order, trialId) then
			return false, "UnknownTrial"
		end
		if order[#character.trials + 1] ~= trialId then
			-- Trials are mandatory and sequential (GDD §4.2).
			return false, "OutOfOrder"
		end
	end
	table.insert(character.trials, { id = trialId, approvedBy = actor, at = now })
	Progression.appendLog(character, actor, "ApproveTrial", { trial = trialId }, now)
	return true, nil
end

-- Revokes a Trial and every Trial completed after it, so the record stays
-- sequential. Returns (ok, errOrNil, revokedIds).
function Progression.revokeTrial(character: any, trialId: any, actor: number, now: number): (boolean, string?, { string }?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err, nil
	end
	local index = if type(trialId) == "string" then hasTrial(character, trialId) else nil
	if not index then
		return false, "NotCompleted", nil
	end
	local revoked = {}
	while #character.trials >= index do
		local entry = table.remove(character.trials) :: any
		table.insert(revoked, 1, entry.id)
	end
	Progression.appendLog(character, actor, "RevokeTrial", { trials = revoked }, now)
	return true, nil, revoked
end

function Progression.grantKit(character: any, weaponType: any, level: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if not isNonEmptyString(weaponType) or not passes("WeaponType", weaponType) then
		return false, "InvalidWeaponType"
	end
	if not isWholeNumber(level, 1) then
		return false, "InvalidLevel"
	end
	if GameConfig.Characters.KitLevelCappedByRank and level > character.rank then
		-- One overall rank decides kit eligibility (GDD §4.3).
		return false, "KitLevelAboveRank"
	end
	local previous = character.kits[weaponType]
	character.kits[weaponType] = { level = level, grantedBy = actor, at = now }
	Progression.appendLog(character, actor, "GrantKit", {
		weaponType = weaponType,
		level = level,
		previousLevel = previous and previous.level,
	}, now)
	return true, nil
end

function Progression.revokeKit(character: any, weaponType: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if type(weaponType) ~= "string" or character.kits[weaponType] == nil then
		return false, "NotGranted"
	end
	local previous = character.kits[weaponType]
	character.kits[weaponType] = nil
	Progression.appendLog(character, actor, "RevokeKit", { weaponType = weaponType, level = previous.level }, now)
	return true, nil
end

function Progression.grantAbility(character: any, abilityId: any, source: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if not isNonEmptyString(abilityId) or not passes("Ability", abilityId) then
		return false, "InvalidAbility"
	end
	if not isNonEmptyString(source) then
		return false, "InvalidSource"
	end
	if character.abilities[abilityId] then
		return false, "AlreadyGranted"
	end
	character.abilities[abilityId] = { source = source, grantedBy = actor, at = now }
	Progression.appendLog(character, actor, "GrantAbility", { ability = abilityId, source = source }, now)
	return true, nil
end

function Progression.revokeAbility(character: any, abilityId: any, actor: number, now: number): (boolean, string?)
	local ok, err = requireAlive(character)
	if not ok then
		return false, err
	end
	if type(abilityId) ~= "string" or character.abilities[abilityId] == nil then
		return false, "NotGranted"
	end
	character.abilities[abilityId] = nil
	Progression.appendLog(character, actor, "RevokeAbility", { ability = abilityId }, now)
	return true, nil
end

return Progression
