--!strict
--[[
	Global combat rules. Values marked §19.5 / §19.6 are placeholders until
	the outstanding design decisions in the GDD are settled.
]]

local CombatSettings = {
	-- Seconds a character stays "in combat" after dealing or taking combat
	-- damage. While tagged they cannot switch weapon, change their selected
	-- G ability, or switch character (GDD §5.3, §19.5).
	CombatTagDuration = 20,

	-- Which states block weapon switching (§19.5). Set any to false to allow
	-- switching in that state.
	SwitchBlockedWhen = {
		CombatTagged = true, -- recently dealt or took combat damage
		Busy = true, -- mid-action (windup or recovery)
		Stunned = true,
		Dead = true,
	},

	-- Inputs that arrive this many seconds before the current action ends
	-- are still accepted, to absorb network latency.
	InputLeniency = 0.08,

	-- Remote rate limits (requests per second per player).
	ActionRateLimit = 12,
	EquipRateLimit = 3,

	-- Server-side sanity limits on the aim direction a client sends for
	-- ranged attacks. The server always uses its own position for the origin.
	MaxAimPitchDegrees = 85,

	-- When true, any target that is not a player character can be hit
	-- (wildlife, NPCs). Friendly-fire rules can be added in
	-- CombatService:SetTargetFilter.
	AllowNonPlayerTargets = true,

	-- Studio-only convenience: when there is no character record or no
	-- ownership provider, grant every kit, variation and G ability so the
	-- moveset can be tested. Never applies in a live server.
	StudioGrantAll = true,
}

return table.freeze(CombatSettings)
