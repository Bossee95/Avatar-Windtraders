--[[
	Stations

	Crafting station types (GDD §11.3, §12). A world part tagged "CraftingStation"
	with the attribute StationType = <key> becomes a station. Optional attributes:
		StationId  stable id (defaults to the full name)
		Faction    WorldConfig faction key; only that faction may use it

	Facilities will also provide stations (design doc §3.2). A facility station only
	works while its facility is operational.
]]

return {
	Workbench = { displayName = "Workbench" },
	Forge = { displayName = "Forge" },
	FieldLab = { displayName = "Field Laboratory" },
	Fletchery = { displayName = "Fletchery" },
}
