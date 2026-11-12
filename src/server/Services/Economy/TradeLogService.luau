--[[
	TradeLogService

	Moderator access to trade and satchel records (GDD §8.5, §16.4).

	Entries are kept in server memory (TradeLog) and written to a DataStore in the
	background so they survive the server:
		entry:<id>         the full entry
		player:<userId>    the ids of that player's latest entries (newest last)

	Query({ playerUserId?, since?, until?, status?, kind?, pdEventId?, itemId?, limit? })
	returns this server's matching entries. With playerUserId set it also reads that
	player's persisted entries from other servers and sessions (this yields).

	Moderators query through the QueryTradeLog remote, which requires the
	ViewTradeLogs staff permission, or through the staff tools' commands.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local EconomyConfig = require(ReplicatedStorage.Shared.Economy.EconomyConfig)
local TradeLog = require(script.Parent.TradeLog)
local EconomyDeps = require(script.Parent.EconomyDeps)

local TradeLogService = {}

local PLAYER_INDEX_LIMIT = 200

local store -- DataStore or nil when unavailable (e.g. Studio without API access)

local function persist(entry)
	if not store then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			store:SetAsync("entry:" .. entry.id, entry)
			for _, userId in ipairs(entry.players or {}) do
				store:UpdateAsync("player:" .. tostring(userId), function(ids)
					ids = ids or {}
					table.insert(ids, entry.id)
					while #ids > PLAYER_INDEX_LIMIT do
						table.remove(ids, 1)
					end
					return ids
				end)
			end
		end)
		if not ok then
			warn("[TradeLog] could not persist entry " .. entry.id .. ": " .. tostring(err))
		end
	end)
end

-- Strips values a DataStore cannot hold (Instances, CFrames) before persisting.
local function sanitize(entry)
	local function clean(v)
		local t = typeof(v)
		if t == "table" then
			local out = {}
			for k, x in pairs(v) do
				out[k] = clean(x)
			end
			return out
		elseif t == "string" or t == "number" or t == "boolean" then
			return v
		end
		return nil
	end
	return clean(entry)
end

do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(EconomyConfig.TradeLogDataStore or "EconomyTradeLog_v1")
	end)
	if ok then
		store = result
	else
		warn("[TradeLog] DataStore unavailable, trade logs are kept in memory only: " .. tostring(result))
	end
end

-- Created at load so other services can use it from their Init.
local log = TradeLog.new({
	now = os.time,
	newId = function()
		return HttpService:GenerateGUID(false)
	end,
	limit = EconomyConfig.TradeLogMemoryLimit,
	sink = function(entry)
		persist(sanitize(entry))
	end,
})

function TradeLogService:Start()
	Net.OnInvoke("QueryTradeLog", function(player, query)
		local StaffService = EconomyDeps.service("StaffService")
		if not StaffService then
			return nil
		end
		local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)
		if not StaffService:HasPermission(player, Permissions.Permission.ViewTradeLogs) then
			return nil
		end
		return TradeLogService:Query(query)
	end, {
		rateLimit = 2,
		validate = function(query)
			return query == nil or type(query) == "table"
		end,
	})
end

-- The in-memory log, shared with TradeService and DeathSatchelService.
function TradeLogService:GetLog()
	return log
end

local function sanitizeQuery(query)
	query = type(query) == "table" and query or {}
	local out = {}
	for _, key in ipairs({ "playerUserId", "since", "until" }) do
		if type(query[key]) == "number" then
			out[key] = query[key]
		end
	end
	for _, key in ipairs({ "status", "kind", "pdEventId", "itemId" }) do
		if type(query[key]) == "string" then
			out[key] = query[key]
		end
	end
	out.limit = math.clamp(type(query.limit) == "number" and query.limit or 100, 1, 500)
	return out
end

function TradeLogService:Query(query)
	query = sanitizeQuery(query)
	local results = log:Query(query)
	if not query.playerUserId or not store then
		return results
	end

	-- Merge in this player's persisted entries that are not in memory.
	local seen = {}
	for _, e in ipairs(results) do
		seen[e.id] = true
	end
	local ok, ids = pcall(store.GetAsync, store, "player:" .. tostring(query.playerUserId))
	if ok and ids then
		local scratch = TradeLog.new({ limit = PLAYER_INDEX_LIMIT })
		for _, id in ipairs(ids) do
			if not seen[id] then
				local got, entry = pcall(store.GetAsync, store, "entry:" .. id)
				if got and entry then
					scratch:Record(entry)
				end
			end
		end
		for _, e in ipairs(scratch:Query(query)) do
			table.insert(results, e)
		end
		table.sort(results, function(a, b)
			return a.time > b.time
		end)
		while #results > query.limit do
			table.remove(results)
		end
	end
	return results
end

return TradeLogService
