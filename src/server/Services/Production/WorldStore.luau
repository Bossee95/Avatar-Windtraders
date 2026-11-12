--[[
	WorldStore

	Global (not per-account) world state for production: node state and recipe locks.
	One DataStore key per section, written with UpdateAsync. Falls back to memory in
	Studio without API access, like the core data layer.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductionConfig = require(ReplicatedStorage.Shared.Production.ProductionConfig)

local WorldStore = {}

local store
local memory = {}

local function getStore()
	if store == nil then
		local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, ProductionConfig.WorldStoreName)
		store = ok and result or false
		if not ok then
			warn("[Production] World store unavailable, using memory: " .. tostring(result))
		end
	end
	return store or nil
end

function WorldStore.Load(key)
	local s = getStore()
	if not s then
		return memory[key]
	end
	local ok, value = pcall(s.GetAsync, s, key)
	if not ok then
		warn(("[Production] Could not load %s: %s"):format(key, tostring(value)))
		return nil
	end
	return value
end

function WorldStore.Save(key, value)
	local s = getStore()
	if not s then
		memory[key] = value
		return true
	end
	local ok, err = pcall(s.UpdateAsync, s, key, function()
		return value
	end)
	if not ok then
		warn(("[Production] Could not save %s: %s"):format(key, tostring(err)))
	end
	return ok
end

return WorldStore
