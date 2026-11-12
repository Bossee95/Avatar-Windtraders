--[[
	SkinStore

	Rules for account-wide weapon skin ownership (GDD §7.3, §16.6), as pure functions
	over an `owned` table: { [skinId] = { grantedBy, grantedAt, note } }.

	SkinService keeps that table in the account-scope "Skins" data section, which
	Permanent Death never touches. There is intentionally no transfer or trade function:
	skins are granted by the Development Team and stay with the account.

	A skin only changes appearance. Owning one never grants a weapon kit; combat code
	must still check the character's Loreteam-assigned kits.
]]

local SkinStore = {}

local function validId(skinId)
	return type(skinId) == "string" and skinId ~= "" and #skinId <= 100
end

function SkinStore.Grant(owned, skinId, grantedBy, grantedAt, note)
	if not validId(skinId) then
		return false, "InvalidSkinId"
	end
	if owned[skinId] then
		return false, "AlreadyOwned"
	end
	owned[skinId] = { grantedBy = grantedBy, grantedAt = grantedAt, note = note }
	return true
end

function SkinStore.Revoke(owned, skinId)
	if not owned[skinId] then
		return false, "NotOwned"
	end
	owned[skinId] = nil
	return true
end

function SkinStore.Owns(owned, skinId)
	return owned ~= nil and owned[skinId] ~= nil
end

function SkinStore.List(owned)
	local list = {}
	for skinId in pairs(owned or {}) do
		table.insert(list, skinId)
	end
	table.sort(list)
	return list
end

return SkinStore
