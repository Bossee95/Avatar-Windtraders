--[[
	Remotes for gathering and crafting. Net merges every *Remotes module.

	Functions (client -> server):
		GatherStart     nodeId                 -> (ok, errOrSeconds)
		CraftStart      recipeId, stationId    -> (ok, errOrSeconds)
		CraftList       stationId              -> { { id, displayName, craftTime, inputs, outputs, ok, reason? } }
		ChannelCancel   ()                     -> (ok)
		ProductionAdmin action, args           -> (ok, resultOrError)   staff only

	Events (server -> client):
		ChannelEnded    { kind, id, ok, reason?, items? }
		NodeState       { nodeId, remaining, capacity, enabled }
]]

return {
	Events = {
		ChannelEnded = true,
		NodeState = true,
	},
	Functions = {
		GatherStart = true,
		CraftStart = true,
		CraftList = true,
		ChannelCancel = true,
		ProductionAdmin = true,
	},
}
