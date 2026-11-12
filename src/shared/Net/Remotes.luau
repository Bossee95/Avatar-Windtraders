--!strict
--[[
	Core remotes. Other systems declare theirs in their own ModuleScript under
	Shared whose name ends in "Remotes" (e.g. Shared/Combat/CombatRemotes.luau)
	with the same { Events, Functions } shape; Net merges them all. The server
	creates every remote under ReplicatedStorage.Remotes at boot, and Net
	errors on any name that isn't declared (so typos fail loudly).
]]

return {
	-- RemoteEvents
	Events = {
		-- Core
		AccountState = true, -- server -> client: account summary for the character screen
	},

	-- RemoteFunctions (client -> server request/response only; the server never invokes clients)
	Functions = {
		-- Core
		CreateCharacter = true, -- { name, faction, role } -> (ok, idOrError)
		SelectCharacter = true, -- characterId -> (ok, error)
		GetAccountState = true, -- () -> account summary (same shape as AccountState)
	},
}
