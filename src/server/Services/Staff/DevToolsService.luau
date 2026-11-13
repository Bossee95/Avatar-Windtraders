--!strict
-- Development Team tools (GDD §2.6, §7, §17): account-wide weapon skins.
-- Skin storage is owned by SkinService (inventory thread); this adds the
-- permission check and the audit entry. G abilities from approved purchases
-- go through LoreteamService:GrantAbility with source "Purchase", which
-- Development staff are allowed to use.
--
--   :GrantSkin(actor, userId, skinId, note?)  -> (ok, err)  [AssignSkins]
--   :RevokeSkin(actor, userId, skinId, note?) -> (ok, err)  [AssignSkins]
--   :ListSkins(actor, userId)                 -> ({ string }?, err)  [AssignSkins or ViewRecords]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)

local AuditLogService = require(script.Parent.AuditLogService)
local StaffService = require(script.Parent.StaffService)

local P = Permissions.Permission

local DevToolsService = {}

local function getSkinService(): any
	local ok, service = pcall(Loader.Get, "SkinService")
	return if ok then service else nil
end

local function validSkinId(skinId: any): boolean
	return type(skinId) == "string" and skinId ~= "" and #skinId <= 64
end

function DevToolsService:GrantSkin(actor: Player, userId: number, skinId: string, note: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.AssignSkins)
	if not allowed then
		return false, permErr
	end
	if not validSkinId(skinId) then
		return false, "Name the skin id."
	end
	local SkinService = getSkinService()
	if SkinService == nil then
		return false, "Skins are not available yet (SkinService is not loaded)."
	end
	local ok, err = SkinService:GrantSkin(actor.UserId, userId, skinId)
	if not ok then
		return false, tostring(err)
	end
	AuditLogService:Record(actor.UserId, "Dev.GrantSkin", userId, { skinId = skinId, note = note })
	return true, nil
end

function DevToolsService:RevokeSkin(actor: Player, userId: number, skinId: string, note: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.AssignSkins)
	if not allowed then
		return false, permErr
	end
	if not validSkinId(skinId) then
		return false, "Name the skin id."
	end
	local SkinService = getSkinService()
	if SkinService == nil then
		return false, "Skins are not available yet (SkinService is not loaded)."
	end
	local ok, err = SkinService:RevokeSkin(actor.UserId, userId, skinId)
	if not ok then
		return false, tostring(err)
	end
	AuditLogService:Record(actor.UserId, "Dev.RevokeSkin", userId, { skinId = skinId, note = note })
	return true, nil
end

function DevToolsService:ListSkins(actor: Player, userId: number): ({ string }?, string?)
	if not (StaffService:HasPermission(actor, P.AssignSkins) or StaffService:HasPermission(actor, P.ViewRecords)) then
		return nil, "You do not have permission to do that."
	end
	local SkinService = getSkinService()
	if SkinService == nil then
		return nil, "Skins are not available yet (SkinService is not loaded)."
	end
	return SkinService:GetSkins(userId), nil
end

return DevToolsService
