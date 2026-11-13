--[[
	SkinService

	Account-wide weapon skin storage (GDD §7.3, §16.6). Skins live in the account-scope
	"Skins" data section, which Permanent Death never touches.

	The Dev Team tool in the staff thread does the permission check (AssignSkins) and
	writes the audit entry. This service only stores and validates. All calls work for
	offline accounts too (via DataService:UpdateOffline).

	There is no trade or transfer function, on purpose.
]]

local Players = game:GetService("Players")

local SkinStore = require(script.Parent.SkinStore)
local EconomyDeps = require(script.Parent.EconomyDeps)

local SkinService = {}

local SECTION = "Skins"

local function withOwned(userId, fn)
	local DataService = EconomyDeps.service("DataService")
	local player = Players:GetPlayerByUserId(userId)
	if player then
		local section = DataService:GetAccountSection(player, SECTION)
		if not section then
			return false, "AccountNotLoaded"
		end
		return fn(section.owned)
	end
	local result, reason
	local ok, err = DataService:UpdateOffline(userId, function(account)
		local section = account.sections[SECTION]
		if not section then
			section = { owned = {} }
			account.sections[SECTION] = section
		end
		section.owned = section.owned or {}
		result, reason = fn(section.owned)
	end)
	if not ok then
		return false, err
	end
	return result, reason
end

function SkinService:Init()
	EconomyDeps.service("DataService"):RegisterSection(SECTION, { scope = "Account", default = { owned = {} } })
end

-- Returns ok, err.
function SkinService:GrantSkin(actorUserId, userId, skinId, note)
	return withOwned(userId, function(owned)
		return SkinStore.Grant(owned, skinId, actorUserId, os.time(), note)
	end)
end

function SkinService:RevokeSkin(_actorUserId, userId, skinId)
	return withOwned(userId, function(owned)
		return SkinStore.Revoke(owned, skinId)
	end)
end

-- Returns { skinId } (sorted), or an empty list if the account cannot be read.
function SkinService:GetSkins(userId)
	local list = {}
	withOwned(userId, function(owned)
		list = SkinStore.List(owned)
		return true
	end)
	return list
end

-- Fast check for online players (e.g. when equipping a cosmetic).
function SkinService:Owns(player, skinId)
	local DataService = EconomyDeps.service("DataService")
	local section = DataService and DataService:GetAccountSection(player, SECTION)
	return section ~= nil and SkinStore.Owns(section.owned, skinId)
end

return SkinService
