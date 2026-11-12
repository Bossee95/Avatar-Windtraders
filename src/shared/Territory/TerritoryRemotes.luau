--[[
	Remotes for facilities, territory and entitlements. Net merges every *Remotes module.

	Functions (client -> server):
		FacilityPlace       typeId, zoneId               -> (ok, facilityIdOrErr)
		FacilityContribute  facilityId, itemId, qty      -> (ok, acceptedOrErr)
		FacilityWork        facilityId                   -> (ok, secondsOrErr)   build channel
		FacilityRepair      facilityId                   -> (ok, secondsOrErr)   repair channel
		TerritoryGetState   ()                           -> { territory snapshot }
		EntitlementList     ()                           -> { public entitlement view }
		ChallengeSubmit     entitlementId, method, notes -> (ok, challengeIdOrErr)

	Events (server -> client):
		FacilityState   facility snapshot
		TerritoryState  territory snapshot
]]

return {
	Events = {
		FacilityState = true,
		TerritoryState = true,
	},
	Functions = {
		FacilityPlace = true,
		FacilityContribute = true,
		FacilityWork = true,
		FacilityRepair = true,
		TerritoryGetState = true,
		EntitlementList = true,
		ChallengeSubmit = true,
	},
}
