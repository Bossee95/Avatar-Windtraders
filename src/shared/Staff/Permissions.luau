--!strict
-- Staff roles and the permissions each role holds, following GDD §17.
-- Shared so client UI can hide tools a player cannot use; the server is
-- always the authority and re-checks every action.

local Permissions = {}

Permissions.Role = table.freeze({
	Loreteam = "Loreteam",
	Moderation = "Moderation",
	Development = "Development",
	-- Superuser for the game owner. Holds every permission. Keep this list tiny.
	Owner = "Owner",
})

Permissions.Permission = table.freeze({
	-- Loreteam (§2.4, §4.4, §17)
	ControlPDEvent = "ControlPDEvent", -- start, end, change phase
	ManageRanks = "ManageRanks", -- grant, lower, revoke faction rank
	ManageTrials = "ManageTrials", -- record or revoke Trial completion
	AssignKits = "AssignKits", -- assign or revoke weapon kits
	AssignLoreGAbilities = "AssignLoreGAbilities", -- G abilities from lore, events, contributions

	-- Loreteam and Moderation
	PausePDEvent = "PausePDEvent", -- pause and resume (supervision, emergencies)

	-- Moderation (§2.5, §3.4, §17)
	ConfirmDeath = "ConfirmDeath", -- confirm or dismiss PD death reports
	ViewTradeLogs = "ViewTradeLogs",
	ManageAccess = "ManageAccess", -- whitelist add/remove for the closed community

	-- Development (§2.6, §7, §17)
	AssignSkins = "AssignSkins", -- account-wide weapon skins
	AssignPurchasedGAbilities = "AssignPurchasedGAbilities", -- G abilities from approved purchases

	-- All staff
	ViewAuditLog = "ViewAuditLog",
	ViewRecords = "ViewRecords", -- read character progression records (§16.1)
})

local P = Permissions.Permission
local R = Permissions.Role

-- Role -> set of permissions. Neither team assumes the other's
-- responsibilities (§17): Moderation and Development cannot touch ranks,
-- Trials or kits; the Loreteam cannot confirm deaths or assign skins.
Permissions.RolePermissions = table.freeze({
	[R.Loreteam] = table.freeze({
		[P.ControlPDEvent] = true,
		[P.PausePDEvent] = true,
		[P.ManageRanks] = true,
		[P.ManageTrials] = true,
		[P.AssignKits] = true,
		[P.AssignLoreGAbilities] = true,
		[P.ViewAuditLog] = true,
		[P.ViewRecords] = true,
	}),
	[R.Moderation] = table.freeze({
		[P.PausePDEvent] = true,
		[P.ConfirmDeath] = true,
		[P.ViewTradeLogs] = true,
		[P.ManageAccess] = true,
		[P.ViewAuditLog] = true,
		[P.ViewRecords] = true,
	}),
	[R.Development] = table.freeze({
		[P.AssignSkins] = true,
		[P.AssignPurchasedGAbilities] = true,
		[P.ViewAuditLog] = true,
		[P.ViewRecords] = true,
	}),
})

function Permissions.RoleHas(role: string, permission: string): boolean
	if role == R.Owner then
		return P[permission] ~= nil
	end
	local set = Permissions.RolePermissions[role]
	return set ~= nil and set[permission] == true
end

function Permissions.RolesHave(roles: { string }, permission: string): boolean
	for _, role in roles do
		if Permissions.RoleHas(role, permission) then
			return true
		end
	end
	return false
end

function Permissions.IsValidRole(role: any): boolean
	return type(role) == "string" and R[role] ~= nil
end

return table.freeze(Permissions)
