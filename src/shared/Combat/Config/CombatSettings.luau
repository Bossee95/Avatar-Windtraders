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

	-- Defence (GDD §6.6). First values come from the original Studio combat.
	-- Hold F to block, Q to dodge.
	HitStun = 0.7, -- seconds a struck character can't act (movement is unaffected)
	Block = {
		MaxCounts = 6, -- charges; each blocked hit drains the attack's blockDrain (default 1)
		CountRegenTime = 4, -- seconds per charge while not blocking
		BlockCooldown = 1, -- after lowering the block
		BreakLockout = 1.5, -- after the block breaks
		HitLockout = 0.7, -- after taking an unblocked hit
		PerfectWindowStart = 0, -- seconds after raising the block
		PerfectWindowEnd = 0.58,
		BlockBrokenDamageMultiplier = 1.2,
		PerfectBlockStun = 0.8, -- on the attacker (reference clip: ~0.5-1 s)
		BlockBreakStun = 1.5, -- on the defender
		WalkSpeedMultiplier = 0.5, -- while holding a block
	},
	Dodge = {
		MaxCharges = 2,
		ChargeCooldown = 4, -- per charge
		IFrameDuration = 0.4,
		Distance = 15, -- studs, applied by the dodging client and checked by the server
		Duration = 0.3,
	},
	DefenseRateLimit = 8,

	-- Knockback forces in Actions are multiplied by this. Pushes are held for
	-- Push.DURATION so they survive Humanoid control: force 40 moves ~7 studs.
	KnockbackScale = 0.6,

	-- Lag compensation for melee (Box and Radius hitboxes). A player target the
	-- server-time hitbox misses still counts if it was inside the hitbox where
	-- the attacker saw it: rewound by the attacker's ping plus
	-- InterpolationDelay, never more than MaxRewind. Ranged hits use server time.
	LagCompensation = {
		Enabled = true,
		SampleRate = 30, -- position samples per second
		MaxRewind = 0.4, -- seconds
		InterpolationDelay = 0.1, -- how far behind clients render other players
		Padding = 1.5, -- studs of forgiveness around the hitbox
	},

	-- Downed, carry and execution (GDD §6.7). V carries, B executes.
	Knock = {
		HealthLimit = 6, -- a character is downed here instead of dying
		Duration = 7, -- seconds until they get up
		ExtendOnDamage = 3, -- seconds added per hit while down, capped at Duration
		GripDuration = 3, -- an execution takes this long and can be interrupted
		DropImmunity = 1, -- seconds before a dropped character can be picked up again
		SearchRadius = 7, -- studs to the downed character
		RateLimit = 4,
	},

	-- Studio-only convenience: when there is no character record or no
	-- ownership provider, grant every kit, variation and G ability so the
	-- moveset can be tested. Never applies in a live server.
	StudioGrantAll = true,
}

return table.freeze(CombatSettings)
