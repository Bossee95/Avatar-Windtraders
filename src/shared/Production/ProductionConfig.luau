--[[
	ProductionConfig

	Tunables and open-decision flags for gathering and crafting (GDD §10, §11).
	Content (nodes, recipes, stations) lives in Production/Config/.
]]

return {
	-- GDD §3.1 places gathering and crafting inside PD events (design doc Q2).
	-- Turn these off only for testing.
	GatherRequiresActivePD = true,
	CraftRequiresActivePD = true,
	-- Paused PDs block gathering and crafting.
	AllowWhilePaused = false,

	-- How far (studs) a player may be from a node or station while channelling.
	GatherRange = 10,
	CraftRange = 12,

	-- How often (seconds) the server re-checks a running channel.
	ChannelCheckInterval = 0.25,

	-- Taking damage or entering combat cancels a channel.
	CancelChannelOnCombat = true,

	-- Seconds between saves of node state to the world store.
	WorldSaveInterval = 120,
	WorldStoreName = "ProductionWorld_v1",

	-- Faction permission flags used by recipes' `permission` field (GDD §11.3).
	-- [faction][role] = { flag = true }. Faction leadership decides who holds them;
	-- edit here until a faction-permission system exists. Leadership roles
	-- (WorldConfig `leadership = true`) hold every flag.
	RolePermissions = {
		FactionA = {
			Engineering = { craft_weapons = true, build = true },
			Logistics = { build = true },
		},
		FactionB = {
			Craftsperson = { craft_weapons = true, build = true },
		},
	},
}
