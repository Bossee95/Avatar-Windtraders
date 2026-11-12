--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)

local R, P = Permissions.Role, Permissions.Permission

return function(t)
	t.test("only the Loreteam controls ranks, Trials, kits and the PD event", function()
		for _, perm in { P.ManageRanks, P.ManageTrials, P.AssignKits, P.ControlPDEvent, P.AssignLoreGAbilities } do
			t.expect(Permissions.RoleHas(R.Loreteam, perm)).toBe(true)
			t.expect(Permissions.RoleHas(R.Moderation, perm)).toBe(false)
			t.expect(Permissions.RoleHas(R.Development, perm)).toBe(false)
		end
	end)

	t.test("only Moderation confirms deaths and reads trade logs", function()
		for _, perm in { P.ConfirmDeath, P.ViewTradeLogs, P.ManageAccess } do
			t.expect(Permissions.RoleHas(R.Moderation, perm)).toBe(true)
			t.expect(Permissions.RoleHas(R.Loreteam, perm)).toBe(false)
			t.expect(Permissions.RoleHas(R.Development, perm)).toBe(false)
		end
	end)

	t.test("only Development assigns skins and purchased G abilities", function()
		for _, perm in { P.AssignSkins, P.AssignPurchasedGAbilities } do
			t.expect(Permissions.RoleHas(R.Development, perm)).toBe(true)
			t.expect(Permissions.RoleHas(R.Loreteam, perm)).toBe(false)
			t.expect(Permissions.RoleHas(R.Moderation, perm)).toBe(false)
		end
	end)

	t.test("territory, facilities, entitlements and recipes are Loreteam-only; resources are Loreteam + Development", function()
		for _, perm in { P.ManageTerritory, P.ManageFacilities, P.ManageEntitlements, P.ManageRecipes } do
			t.expect(Permissions.RoleHas(R.Loreteam, perm)).toBe(true)
			t.expect(Permissions.RoleHas(R.Moderation, perm)).toBe(false)
			t.expect(Permissions.RoleHas(R.Development, perm)).toBe(false)
		end
		t.expect(Permissions.RoleHas(R.Loreteam, P.ManageResources)).toBe(true)
		t.expect(Permissions.RoleHas(R.Development, P.ManageResources)).toBe(true)
		t.expect(Permissions.RoleHas(R.Moderation, P.ManageResources)).toBe(false)
	end)

	t.test("Loreteam and Moderation can both pause", function()
		t.expect(Permissions.RoleHas(R.Loreteam, P.PausePDEvent)).toBe(true)
		t.expect(Permissions.RoleHas(R.Moderation, P.PausePDEvent)).toBe(true)
		t.expect(Permissions.RoleHas(R.Development, P.PausePDEvent)).toBe(false)
	end)

	t.test("Owner holds every permission, unknown ones are refused", function()
		for _, perm in P do
			t.expect(Permissions.RoleHas(R.Owner, perm)).toBe(true)
		end
		t.expect(Permissions.RoleHas(R.Owner, "LaunchNukes")).toBe(false)
		t.expect(Permissions.RolesHave({}, P.ViewAuditLog)).toBe(false)
		t.expect(Permissions.RolesHave({ R.Development, R.Moderation }, P.ConfirmDeath)).toBe(true)
	end)
end
