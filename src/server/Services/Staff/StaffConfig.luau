--!strict
-- Staff and access configuration. Edit this file to set up the community.
--
-- The place owner is always Owner. Other roles come from two sources, combined:
--   1. Roblox group rank: if GroupId is set, each entry in GroupRankRoles
--      grants a role to members at or above MinRank.
--   2. Explicit user ids in UserRoles, for staff outside the group or for
--      testing in Studio.
--
-- Access (§15.1 closed community) is granted if ANY of these is true:
--   * the player holds a staff role,
--   * the player is in the group at or above Access.MinGroupRank,
--   * the player's user id is in Access.StaticWhitelist,
--   * a moderator whitelisted them in-game (stored in a DataStore).

return table.freeze({
	-- Roblox group that owns the community. 0 disables group checks.
	GroupId = 0,

	GroupRankRoles = table.freeze({
		-- { MinRank = 200, Role = "Loreteam" },
		-- { MinRank = 210, Role = "Moderation" },
		-- { MinRank = 220, Role = "Development" },
		-- { MinRank = 255, Role = "Owner" },
	}),

	-- In Studio, every tester is Owner so staff tools can be tried locally.
	StudioOwner = true,

	-- [userId] = { roles }
	UserRoles = table.freeze({
		[126830207] = { "Owner" }, -- Bossee
	}) :: { [number]: { string } },

	Access = table.freeze({
		-- Closed community gate. Turn off only for open playtests.
		Enabled = true,
		-- Group members at or above this rank may join. 0 = group membership not used.
		MinGroupRank = 0,
		StaticWhitelist = table.freeze({
			-- 123456789,
		}) :: { number },
		-- Studio play-solo bypasses the gate so developers can test.
		AllowInStudio = true,
		KickMessage = "This is a closed community. Apply through the community group to be whitelisted.",
	}),

	-- DataStore names. Change the suffix to wipe data between test builds.
	DataStores = table.freeze({
		Whitelist = "Pandora_Whitelist_v1",
		AuditLog = "Pandora_AuditLog_v1",
		PDEvent = "Pandora_PDEvent_v1",
		Deaths = "Pandora_DeathReports_v1",
	}),

	-- MessagingService topic used to keep PD state in sync across servers.
	PDEventTopic = "Pandora_PDEvent",
})
