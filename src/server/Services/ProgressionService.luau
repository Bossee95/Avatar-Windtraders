--!strict
--[[
	ProgressionService: the record-keeping side of Loreteam authority
	(GDD §4, §16.1). See docs/CORE_API.md §8.

	No permission checks here: the staff tools check StaffService permissions
	and then call these. Every method takes the acting staff member's userId,
	works whether or not the player is online, appends to character.log and
	returns (ok, err).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local DataService = require(script.Parent.DataService)
local CharacterService = require(script.Parent.CharacterService)
local Progression = require(script.Parent.Parent.Rules.Progression)

local ProgressionService = {}

-- (actorUserId, userId, characterId, action, details)
ProgressionService.Changed = Signal.new()

local function apply(
	actor: any,
	userId: any,
	characterId: any,
	field: string,
	action: string,
	details: { [string]: any },
	mutate: (any) -> (boolean, string?, any?)
): (boolean, string?, any?)
	if type(actor) ~= "number" or type(userId) ~= "number" or type(characterId) ~= "string" then
		return false, "InvalidArguments", nil
	end
	local extra
	local ok, err = DataService:UpdateOffline(userId, function(account)
		local character = account.characters[characterId]
		if character == nil then
			return false, "CharacterNotFound"
		end
		local mutated, reason, more = mutate(character)
		if not mutated then
			return false, reason
		end
		extra = more
		return true, nil
	end)
	if not ok then
		return false, err, nil
	end
	CharacterService:_notifyChanged(userId, characterId, field)
	ProgressionService.Changed:Fire(actor, userId, characterId, action, details)
	return true, nil, extra
end

function ProgressionService:SetFaction(
	actor: number,
	userId: number,
	characterId: string,
	faction: string,
	role: string?
)
	return apply(
		actor,
		userId,
		characterId,
		"Faction",
		"SetFaction",
		{ faction = faction, role = role },
		function(character)
			return Progression.setFaction(character, faction, role, actor, os.time())
		end
	)
end

function ProgressionService:SetRank(actor: number, userId: number, characterId: string, rank: number)
	return apply(actor, userId, characterId, "Rank", "SetRank", { rank = rank }, function(character)
		return Progression.setRank(character, rank, actor, os.time())
	end)
end

function ProgressionService:ApproveTrial(actor: number, userId: number, characterId: string, trialId: string)
	return apply(
		actor,
		userId,
		characterId,
		"Trials",
		"ApproveTrial",
		{ trial = trialId },
		function(character)
			return Progression.approveTrial(character, trialId, actor, os.time())
		end
	)
end

-- Also revokes every Trial completed after `trialId`. Third return value is
-- the list of revoked Trial ids.
function ProgressionService:RevokeTrial(actor: number, userId: number, characterId: string, trialId: string)
	return apply(actor, userId, characterId, "Trials", "RevokeTrial", { trial = trialId }, function(character)
		return Progression.revokeTrial(character, trialId, actor, os.time())
	end)
end

function ProgressionService:GrantKit(
	actor: number,
	userId: number,
	characterId: string,
	weaponType: string,
	level: number
)
	return apply(
		actor,
		userId,
		characterId,
		"Kits",
		"GrantKit",
		{ weaponType = weaponType, level = level },
		function(character)
			return Progression.grantKit(character, weaponType, level, actor, os.time())
		end
	)
end

function ProgressionService:RevokeKit(actor: number, userId: number, characterId: string, weaponType: string)
	return apply(
		actor,
		userId,
		characterId,
		"Kits",
		"RevokeKit",
		{ weaponType = weaponType },
		function(character)
			return Progression.revokeKit(character, weaponType, actor, os.time())
		end
	)
end

function ProgressionService:GrantAbility(
	actor: number,
	userId: number,
	characterId: string,
	abilityId: string,
	source: string
)
	return apply(
		actor,
		userId,
		characterId,
		"Abilities",
		"GrantAbility",
		{ ability = abilityId, source = source },
		function(character)
			return Progression.grantAbility(character, abilityId, source, actor, os.time())
		end
	)
end

function ProgressionService:RevokeAbility(
	actor: number,
	userId: number,
	characterId: string,
	abilityId: string
)
	return apply(
		actor,
		userId,
		characterId,
		"Abilities",
		"RevokeAbility",
		{ ability = abilityId },
		function(character)
			return Progression.revokeAbility(character, abilityId, actor, os.time())
		end
	)
end

--[[
	Lets the owner of a catalog reject unknown ids. kind = "WeaponType" or
	"Ability"; fn(id) -> boolean. Combat registers both in its :Init().
]]
function ProgressionService:SetValidator(kind: string, fn: (string) -> boolean)
	Progression.setValidator(kind, fn)
end

function ProgressionService:GetNextTrial(character: any): string?
	return Progression.getNextTrial(character)
end

return ProgressionService
