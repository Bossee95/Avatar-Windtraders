--!strict
-- Loreteam progression tools (GDD §4, §5, §6.5, §17). Thin, permission-checked
-- and audited wrappers around core's ProgressionService, which owns the data
-- and enforces Trial order. Nothing here is automatic: every change is a staff
-- decision (§4.4).
--
-- Every method takes the acting staff Player, the target userId and an
-- optional characterId (defaults to the target's active character when they
-- are in this server), and returns (ok, err).
--
--   :SetFaction(actor, userId, characterId?, faction, role, note?)      [ManageRanks]
--   :SetRank(actor, userId, characterId?, rank, note?)                  [ManageRanks]
--   :ApproveTrial(actor, userId, characterId?, trialId?, note?)         [ManageTrials]  trialId defaults to the next Trial
--   :RevokeTrial(actor, userId, characterId?, trialId, note?)           [ManageTrials]  also revokes later Trials
--   :GrantKit(actor, userId, characterId?, weaponType, level, note?)    [AssignKits]
--   :RevokeKit(actor, userId, characterId?, weaponType, note?)          [AssignKits]
--   :GrantAbility(actor, userId, characterId?, abilityId, source, note?)  [AssignLoreGAbilities or AssignPurchasedGAbilities by source]
--   :RevokeAbility(actor, userId, characterId?, abilityId, note?)       [either G ability permission]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)

local AuditLogService = require(script.Parent.AuditLogService)
local StaffService = require(script.Parent.StaffService)
local StaffTargets = require(script.Parent.StaffTargets)

local ProgressionService: any = nil
local CharacterService: any = nil

local P = Permissions.Permission

local LoreteamService = {}

-- G ability sources (§6.5) and which permission each needs.
LoreteamService.AbilitySources = table.freeze({
	Lore = P.AssignLoreGAbilities, -- lore accomplishment
	Event = P.AssignLoreGAbilities, -- special event
	Contribution = P.AssignLoreGAbilities, -- exceptional community contribution
	Purchase = P.AssignPurchasedGAbilities, -- approved purchase via the Development Team
})

local MAX_RANK = 100

local function run(
	actor: Player,
	permission: string,
	userId: number,
	characterId: string?,
	action: string,
	details: { [string]: any },
	call: (charId: string) -> (boolean, string?)
): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, permission)
	if not allowed then
		return false, permErr
	end
	local charId, charErr = StaffTargets.ResolveCharacterId(CharacterService, userId, characterId)
	if charId == nil then
		return false, charErr
	end
	local ok, err = call(charId)
	if not ok then
		return false, tostring(err)
	end
	details.characterId = charId
	AuditLogService:Record(actor.UserId, action, userId, details)
	return true, nil
end

function LoreteamService:SetFaction(actor: Player, userId: number, characterId: string?, faction: string, role: string, note: string?)
	return run(actor, P.ManageRanks, userId, characterId, "Lore.SetFaction", { faction = faction, role = role, note = note }, function(charId)
		return ProgressionService:SetFaction(actor.UserId, userId, charId, faction, role)
	end)
end

function LoreteamService:SetRank(actor: Player, userId: number, characterId: string?, rank: number, note: string?)
	if type(rank) ~= "number" or rank < 0 or rank > MAX_RANK or rank % 1 ~= 0 then
		return false, `Rank must be a whole number from 0 to {MAX_RANK}.`
	end
	return run(actor, P.ManageRanks, userId, characterId, "Lore.SetRank", { rank = rank, note = note }, function(charId)
		return ProgressionService:SetRank(actor.UserId, userId, charId, rank)
	end)
end

function LoreteamService:ApproveTrial(actor: Player, userId: number, characterId: string?, trialId: string?, note: string?)
	local details: { [string]: any } = { note = note }
	return run(actor, P.ManageTrials, userId, characterId, "Lore.ApproveTrial", details, function(charId)
		local approved = trialId
		if approved == nil or approved == "" then
			local player = Players:GetPlayerByUserId(userId)
			local character = player and CharacterService:GetCharacter(player, charId)
			if character == nil then
				return false, "Name the Trial id (the player is not in this server, so the next Trial cannot be looked up)."
			end
			approved = ProgressionService:GetNextTrial(character)
			if approved == nil then
				return false, "That character has completed every Trial for their faction."
			end
		end
		details.trialId = approved
		return ProgressionService:ApproveTrial(actor.UserId, userId, charId, approved)
	end)
end

function LoreteamService:RevokeTrial(actor: Player, userId: number, characterId: string?, trialId: string, note: string?)
	if type(trialId) ~= "string" or trialId == "" then
		return false, "Name the Trial to revoke."
	end
	return run(actor, P.ManageTrials, userId, characterId, "Lore.RevokeTrial", { trialId = trialId, note = note }, function(charId)
		return ProgressionService:RevokeTrial(actor.UserId, userId, charId, trialId)
	end)
end

function LoreteamService:GrantKit(actor: Player, userId: number, characterId: string?, weaponType: string, level: number, note: string?)
	if type(weaponType) ~= "string" or weaponType == "" then
		return false, "Name the weapon type."
	end
	if type(level) ~= "number" or level < 1 or level % 1 ~= 0 then
		return false, "Kit level must be a whole number of 1 or more."
	end
	return run(actor, P.AssignKits, userId, characterId, "Lore.GrantKit", { weaponType = weaponType, level = level, note = note }, function(charId)
		return ProgressionService:GrantKit(actor.UserId, userId, charId, weaponType, level)
	end)
end

function LoreteamService:RevokeKit(actor: Player, userId: number, characterId: string?, weaponType: string, note: string?)
	if type(weaponType) ~= "string" or weaponType == "" then
		return false, "Name the weapon type."
	end
	return run(actor, P.AssignKits, userId, characterId, "Lore.RevokeKit", { weaponType = weaponType, note = note }, function(charId)
		return ProgressionService:RevokeKit(actor.UserId, userId, charId, weaponType)
	end)
end

function LoreteamService:GrantAbility(actor: Player, userId: number, characterId: string?, abilityId: string, source: string, note: string?)
	local permission = LoreteamService.AbilitySources[source]
	if permission == nil then
		return false, "Source must be one of: Lore, Event, Contribution, Purchase."
	end
	if type(abilityId) ~= "string" or abilityId == "" then
		return false, "Name the G ability."
	end
	return run(actor, permission, userId, characterId, "GAbility.Grant", { abilityId = abilityId, source = source, note = note }, function(charId)
		return ProgressionService:GrantAbility(actor.UserId, userId, charId, abilityId, source)
	end)
end

function LoreteamService:RevokeAbility(actor: Player, userId: number, characterId: string?, abilityId: string, note: string?)
	if type(abilityId) ~= "string" or abilityId == "" then
		return false, "Name the G ability."
	end
	local permission = if StaffService:HasPermission(actor, P.AssignLoreGAbilities)
		then P.AssignLoreGAbilities
		else P.AssignPurchasedGAbilities
	return run(actor, permission, userId, characterId, "GAbility.Revoke", { abilityId = abilityId, note = note }, function(charId)
		return ProgressionService:RevokeAbility(actor.UserId, userId, charId, abilityId)
	end)
end

function LoreteamService:Init()
	ProgressionService = require(script.Parent.Parent.ProgressionService)
	CharacterService = require(script.Parent.Parent.CharacterService)
end

return LoreteamService
