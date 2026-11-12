--[[
	Facilities (GDD §12). One entry per facility type, defined by what it does.

	Fields:
		displayName   shown to players
		factions      WorldConfig faction keys that may build it
		cost          { [itemId] = qty } materials to deposit before it can finish
		buildPoints   build work needed (each work channel adds TerritoryConfig.WorkPerChannel)
		maxHealth     health once operational
		size          Vector3-like { x, y, z } for the placeholder part when no model exists
		provides      list of functions:
		                "station:<Stations key>"  a crafting station (works while Operational)
		                "spawn_point" | "heal_zone" | "comms" | "ceremony_site" | "storage"
		              Only stations are wired so far; the rest are markers for later systems.
		capturable    true if attackers can capture it
		captureRadius studs around the facility counted for capture
		captureTime   seconds of uncontested presence to capture
		anchor        true if owning it controls its territory (design doc §5.2)

	A model at ServerStorage.FacilityModels.<key> is cloned if it exists; otherwise a
	plain block is used. Materials are the placeholder ItemDefinitions ids.
]]

local A, B = "FactionA", "FactionB"

return {
	-- Faction A (GDD §12.2)
	ForwardBase = {
		displayName = "Forward Operating Base",
		factions = { A },
		cost = { ["Material.Common"] = 120, ["Material.Industrial"] = 40 },
		buildPoints = 300,
		maxHealth = 5000,
		size = { x = 40, y = 12, z = 40 },
		provides = { "spawn_point", "storage" },
		capturable = true,
		captureRadius = 30,
		captureTime = 120,
		anchor = true,
	},
	ExtractionStation = {
		displayName = "Resource Extraction Station",
		factions = { A },
		cost = { ["Material.Common"] = 60, ["Material.Industrial"] = 30 },
		buildPoints = 180,
		maxHealth = 2500,
		size = { x = 20, y = 14, z = 20 },
		provides = { "storage" },
		capturable = true,
		captureRadius = 20,
		captureTime = 90,
	},
	WeaponFactory = {
		displayName = "Weapon Manufacturing Facility",
		factions = { A },
		cost = { ["Material.Common"] = 80, ["Material.Industrial"] = 40 },
		buildPoints = 200,
		maxHealth = 3000,
		size = { x = 24, y = 12, z = 18 },
		provides = { "station:Forge" },
		capturable = true,
		captureRadius = 20,
		captureTime = 90,
	},
	MedicalStation = {
		displayName = "Medical Station",
		factions = { A },
		cost = { ["Material.Common"] = 40, ["Material.Industrial"] = 10 },
		buildPoints = 120,
		maxHealth = 1500,
		size = { x = 16, y = 8, z = 16 },
		provides = { "heal_zone", "station:FieldLab" },
		capturable = false,
	},
	ResearchLab = {
		displayName = "Research Laboratory",
		factions = { A },
		cost = { ["Material.Industrial"] = 50, ["Material.Rare"] = 5 },
		buildPoints = 200,
		maxHealth = 2000,
		size = { x = 20, y = 10, z = 20 },
		provides = { "station:FieldLab" },
		capturable = true,
		captureRadius = 20,
		captureTime = 90,
	},
	CommsTower = {
		displayName = "Communications Facility",
		factions = { A },
		cost = { ["Material.Industrial"] = 40 },
		buildPoints = 120,
		maxHealth = 1500,
		size = { x = 8, y = 30, z = 8 },
		provides = { "comms" },
		capturable = true,
		captureRadius = 15,
		captureTime = 60,
	},
	Outpost = {
		displayName = "Defensive Outpost",
		factions = { A },
		cost = { ["Material.Common"] = 50, ["Material.Industrial"] = 10 },
		buildPoints = 100,
		maxHealth = 3500,
		size = { x = 14, y = 10, z = 14 },
		provides = {},
		capturable = true,
		captureRadius = 15,
		captureTime = 60,
		anchor = true,
	},
	Depot = {
		displayName = "Storage and Logistics Facility",
		factions = { A },
		cost = { ["Material.Common"] = 60 },
		buildPoints = 120,
		maxHealth = 2000,
		size = { x = 24, y = 10, z = 24 },
		provides = { "storage" },
		capturable = true,
		captureRadius = 20,
		captureTime = 90,
	},

	-- Faction B (GDD §12.3)
	Settlement = {
		displayName = "Clan Settlement",
		factions = { B },
		cost = { ["Material.Natural"] = 150, ["Material.Common"] = 30 },
		buildPoints = 300,
		maxHealth = 5000,
		size = { x = 40, y = 14, z = 40 },
		provides = { "spawn_point", "storage" },
		capturable = true,
		captureRadius = 30,
		captureTime = 120,
		anchor = true,
	},
	HuntingCamp = {
		displayName = "Hunting Camp",
		factions = { B },
		cost = { ["Material.Natural"] = 40 },
		buildPoints = 80,
		maxHealth = 1200,
		size = { x = 14, y = 6, z = 14 },
		provides = { "storage" },
		capturable = true,
		captureRadius = 15,
		captureTime = 60,
	},
	GatheringArea = {
		displayName = "Gathering Area",
		factions = { B },
		cost = { ["Material.Natural"] = 50 },
		buildPoints = 100,
		maxHealth = 1500,
		size = { x = 20, y = 4, z = 20 },
		provides = { "storage" },
		capturable = true,
		captureRadius = 20,
		captureTime = 60,
	},
	CraftingGrounds = {
		displayName = "Weapon Crafting Station",
		factions = { B },
		cost = { ["Material.Natural"] = 60, ["Material.Common"] = 20 },
		buildPoints = 150,
		maxHealth = 2000,
		size = { x = 16, y = 6, z = 16 },
		provides = { "station:Fletchery", "station:Workbench" },
		capturable = true,
		captureRadius = 15,
		captureTime = 90,
	},
	DefensivePosition = {
		displayName = "Defensive Position",
		factions = { B },
		cost = { ["Material.Natural"] = 50, ["Material.Common"] = 20 },
		buildPoints = 100,
		maxHealth = 3500,
		size = { x = 14, y = 10, z = 14 },
		provides = {},
		capturable = true,
		captureRadius = 15,
		captureTime = 60,
		anchor = true,
	},
	HealingArea = {
		displayName = "Healing Area",
		factions = { B },
		cost = { ["Material.Natural"] = 40, ["Material.Rare"] = 2 },
		buildPoints = 120,
		maxHealth = 1500,
		size = { x = 16, y = 4, z = 16 },
		provides = { "heal_zone", "station:FieldLab" },
		capturable = false,
	},
	SacredSite = {
		displayName = "Spiritual and Cultural Site",
		factions = { B },
		cost = { ["Material.Natural"] = 80, ["Material.Rare"] = 5 },
		buildPoints = 200,
		maxHealth = 4000,
		size = { x = 24, y = 8, z = 24 },
		provides = { "ceremony_site" },
		capturable = false,
	},
	Cache = {
		displayName = "Resource Storage",
		factions = { B },
		cost = { ["Material.Natural"] = 50 },
		buildPoints = 100,
		maxHealth = 2000,
		size = { x = 16, y = 8, z = 16 },
		provides = { "storage" },
		capturable = true,
		captureRadius = 15,
		captureTime = 90,
	},
}
