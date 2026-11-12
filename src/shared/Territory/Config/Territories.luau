--[[
	Territories (GDD §13.1).

	Each key is also a WorldConfig.Places key, which holds its display name.

	Fields:
		adjacent     neighbouring territory keys (map display)
		landmark     true for narrative landmarks
		startingController  optional faction key used the first time the world loads

	In the world:
		Parts tagged "BuildZone" are facility slots. Attributes: ZoneId, Territory.
		One facility per zone. Resource nodes set the attribute Territory too.
]]

return {
	NorthRidge = { adjacent = { "Falls" }, landmark = false, startingController = "FactionA" },
	Falls = { adjacent = { "NorthRidge", "Basin" }, landmark = true },
	Basin = { adjacent = { "Falls" }, landmark = false, startingController = "FactionB" },
}
