--!strict
--[[
	GameConfig: tunable numbers and names for the core systems.
]]

return {
	Data = {
		-- Bump the store name only to deliberately start every account fresh.
		StoreName = "Accounts_v1",
		KeyPrefix = "account_",

		AutosaveInterval = 60, -- seconds
		-- A session lock older than this is treated as abandoned (crashed server).
		-- Must be well above AutosaveInterval, since autosave refreshes the lock.
		LockTimeout = 300, -- seconds
		-- How many times to retry loading an account that another server holds
		-- (e.g. the player just teleported/rejoined) before giving up.
		LoadLockRetries = 6,
		LoadLockRetryDelay = 5, -- seconds between retries

		-- Retries for DataStore errors (throttling, outages) on each operation.
		RequestRetries = 5,
		RequestRetryBaseDelay = 1, -- seconds, doubles each retry

		-- Use the in-memory store in Studio when API access is not enabled.
		MockInStudioWithoutApiAccess = true,
	},

	Characters = {
		MaxAliveCharacters = 3, -- per account; dead characters don't count
		NameMinLength = 3,
		NameMaxLength = 24,
		ProgressionLogLimit = 100, -- entries kept in character.log
		-- When true, a weapon kit's level can't exceed the character's overall
		-- rank (GDD §4.3: one rank decides kit eligibility). The Loreteam
		-- still assigns every kit by hand.
		KitLevelCappedByRank = true,
		-- Factions a player may pick when creating a character. Independent
		-- affiliations are assigned by staff with ProgressionService:SetFaction.
		PlayerSelectableFactions = { "FactionA", "FactionB" },
		-- Ordinary (non-PD) deaths respawn the same character after
		-- Players.RespawnTime. Combat can turn this off to run its own downed state.
		RespawnAfterNonPermanentDeath = true,
	},
}
