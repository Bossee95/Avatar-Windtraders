--!strict
--[[
	WorldConfig: the single home for every faction, role and place display name.

	Code everywhere uses the generic KEYS below (FactionA, Military, ...). Only
	the `displayName` strings are shown to players, so the setting can be
	renamed here without touching any system. Do not hard-code names or
	setting-specific assets anywhere else.

	kind:
	  "Primary"      one of the two main factions in the conflict
	  "Independent"  a small, optional affiliation (GDD §2.3); `maxPopulation`
	                 is advisory for staff tools, not enforced by the core

	trials: the ordered list of Trial ids for the faction (GDD §4.2). The
	Loreteam approves each one; ProgressionService only enforces the order.
	Fill these in with the real Trials. A faction with an empty list has no
	order to enforce yet.
]]

export type Role = {
	displayName: string,
	description: string?,
	leadership: boolean?, -- true for roles that lead the faction
}

export type Faction = {
	displayName: string,
	kind: "Primary" | "Independent",
	description: string?,
	roles: { [string]: Role },
	defaultRole: string,
	trials: { string },
	maxPopulation: number?,
}

export type Place = {
	displayName: string,
	description: string?,
}

local WorldConfig = {}

WorldConfig.Factions = {
	-- The human industrial/military faction (GDD §2.1).
	FactionA = {
		displayName = "Faction A",
		kind = "Primary",
		description = "Industrial and military presence focused on extraction and expansion.",
		roles = {
			Command = { displayName = "Command", leadership = true },
			Military = { displayName = "Military" },
			Research = { displayName = "Research and Development" },
			Engineering = { displayName = "Engineering" },
			Logistics = { displayName = "Logistics" },
			Medical = { displayName = "Medical" },
		},
		defaultRole = "Military",
		trials = {
			-- e.g. "A_Induction", "A_FieldOperation", ...
		},
	},

	-- The indigenous clan-based faction (GDD §2.2).
	FactionB = {
		displayName = "Faction B",
		kind = "Primary",
		description = "Clans defending their ancestral territory and traditions.",
		roles = {
			Leader = { displayName = "Clan Leader", leadership = true },
			SpiritualLeader = { displayName = "Spiritual Leader", leadership = true },
			Hunter = { displayName = "Hunter" },
			Warrior = { displayName = "Warrior" },
			Gatherer = { displayName = "Gatherer" },
			Craftsperson = { displayName = "Craftsperson" },
		},
		defaultRole = "Warrior",
		trials = {
			-- e.g. "B_Ceremony", "B_FirstHunt", ...
		},
	},

	-- Rogues: deserters, outcasts and others outside faction authority (GDD §2.3).
	RogueA = {
		displayName = "Rogue",
		kind = "Independent",
		roles = {
			Rogue = { displayName = "Rogue" },
		},
		defaultRole = "Rogue",
		trials = {},
		maxPopulation = 10,
	},

	-- Lone warriors: clan members operating outside clan authority (GDD §2.3).
	RogueB = {
		displayName = "Lone Warrior",
		kind = "Independent",
		roles = {
			LoneWarrior = { displayName = "Lone Warrior" },
		},
		defaultRole = "LoneWarrior",
		trials = {},
		maxPopulation = 10,
	},
} :: { [string]: Faction }

-- Named locations. Other systems (territory, facilities, events) add their
-- keys here.
WorldConfig.Places = {
	World = { displayName = "The World" },
	FactionABase = { displayName = "Faction A Headquarters" },
	FactionBHome = { displayName = "Faction B Home Settlement" },
} :: { [string]: Place }

function WorldConfig.getFaction(key: string): Faction?
	return WorldConfig.Factions[key]
end

function WorldConfig.getFactionName(key: string): string
	local faction = WorldConfig.Factions[key]
	return if faction then faction.displayName else key
end

function WorldConfig.getRoleName(factionKey: string, roleKey: string): string
	local faction = WorldConfig.Factions[factionKey]
	local role = faction and faction.roles[roleKey]
	return if role then role.displayName else roleKey
end

function WorldConfig.getPlaceName(key: string): string
	local place = WorldConfig.Places[key]
	return if place then place.displayName else key
end

function WorldConfig.isValidFaction(key: any): boolean
	return type(key) == "string" and WorldConfig.Factions[key] ~= nil
end

function WorldConfig.isValidRole(factionKey: any, roleKey: any): boolean
	if type(factionKey) ~= "string" or type(roleKey) ~= "string" then
		return false
	end
	local faction = WorldConfig.Factions[factionKey]
	return faction ~= nil and faction.roles[roleKey] ~= nil
end

return WorldConfig
