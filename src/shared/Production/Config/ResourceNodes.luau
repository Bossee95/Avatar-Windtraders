--[[
	ResourceNodes

	Node types (GDD §10.2, §10.3). A world part tagged "ResourceNode" with the
	attribute NodeType = <key> becomes a node of that type. Optional attributes:
		NodeId     stable id, so its state persists across servers (defaults to the full name)
		Territory  territory key (TerritoryService decides access, see the design doc §5.3)

	Fields:
		tier        "Common" | "Industrial" | "Natural" | "Rare" (shown in UI; no hidden rules)
		yields      list of { item = <ItemDefinitions id>, min, max, chance? (0-1, default 1) }
		gatherTime  seconds of uninterrupted channel
		capacity    gathers before the node is depleted (scarcity, GDD §10.3)
		regen       { mode = "PerEvent" }            refill to capacity when a PD starts
		            { mode = "Timed", every = secs } +1 every N seconds during an active PD
		            { mode = "None" }                one-time deposit; staff reseed it
		toolTag     optional item id the gatherer must carry
		factions    optional list of WorldConfig faction keys allowed to gather

	The yields use the placeholder materials from ItemDefinitions. Replace with real content.
]]

return {
	ScrapPile = {
		tier = "Common",
		yields = { { item = "Material.Common", min = 2, max = 4 } },
		gatherTime = 3,
		capacity = 20,
		regen = { mode = "Timed", every = 60 },
	},

	MachineWreck = {
		tier = "Industrial",
		yields = {
			{ item = "Material.Industrial", min = 1, max = 3 },
			{ item = "Material.Common", min = 0, max = 2 },
		},
		gatherTime = 5,
		capacity = 12,
		regen = { mode = "PerEvent" },
	},

	FibrePlant = {
		tier = "Natural",
		yields = { { item = "Material.Natural", min = 2, max = 3 } },
		gatherTime = 3,
		capacity = 15,
		regen = { mode = "Timed", every = 90 },
	},

	CrystalVein = {
		tier = "Rare",
		yields = {
			{ item = "Material.Rare", min = 1, max = 1 },
			{ item = "Material.Rare", min = 1, max = 1, chance = 0.25 },
		},
		gatherTime = 8,
		capacity = 4,
		regen = { mode = "PerEvent" },
	},
}
