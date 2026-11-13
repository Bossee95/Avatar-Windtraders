--!strict
-- Append-only audit log of every staff action.
--
--   AuditLogService:Record(actorUserId, action, targetUserId?, details?)
--   AuditLogService:Query({ actorUserId?, targetUserId?, action?, days?, limit? }) -> { Entry }
--
-- Entries are buffered and flushed to a DataStore every FLUSH_INTERVAL seconds
-- and on shutdown, one key per UTC day ("2026-11-12"). Recent entries also stay
-- in memory so queries in the same server see them before the flush.
-- actorUserId 0 means "the system" (e.g. automatic pause on server restart).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local StaffConfig = require(script.Parent.StaffConfig)

export type Entry = {
	id: string,
	at: number,
	actor: number,
	action: string,
	target: number?,
	details: { [string]: any }?,
}

export type Query = {
	actorUserId: number?,
	targetUserId: number?,
	action: string?,
	days: number?, -- how many UTC days back to read, default 1 (today)
	limit: number?, -- default 50, max 200
}

local AuditLogService = {}

local FLUSH_INTERVAL = 30
local RECENT_LIMIT = 500
local DAY_ENTRY_CAP = 8000 -- keeps each key well under the 4 MB DataStore limit

local store: DataStore? = nil
local pending: { Entry } = {}
local recent: { Entry } = {}

local function dayKey(timestamp: number): string
	return os.date("!%Y-%m-%d", timestamp) :: string
end

-- Details must be DataStore-serialisable; drop anything that is not.
local function sanitize(details: { [string]: any }?): { [string]: any }?
	if details == nil then
		return nil
	end
	local out = {}
	for key, value in details do
		local t = typeof(value)
		if t == "string" then
			out[tostring(key)] = string.sub(value, 1, 500)
		elseif t == "number" or t == "boolean" then
			out[tostring(key)] = value
		elseif t == "table" then
			local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
			out[tostring(key)] = if ok then string.sub(encoded, 1, 500) else "<unserialisable>"
		else
			out[tostring(key)] = tostring(value)
		end
	end
	return out
end

function AuditLogService:Record(actorUserId: number, action: string, targetUserId: number?, details: { [string]: any }?): Entry
	local entry: Entry = {
		id = HttpService:GenerateGUID(false),
		at = os.time(),
		actor = actorUserId,
		action = action,
		target = targetUserId,
		details = sanitize(details),
	}
	table.insert(pending, entry)
	table.insert(recent, entry)
	if #recent > RECENT_LIMIT then
		table.remove(recent, 1)
	end
	print(`[Audit] {actorUserId} {action}{if targetUserId then " -> " .. targetUserId else ""}`)
	return entry
end

function AuditLogService:Flush()
	if #pending == 0 or store == nil then
		return
	end
	local batch = pending
	pending = {}

	local byDay: { [string]: { Entry } } = {}
	for _, entry in batch do
		local key = dayKey(entry.at)
		byDay[key] = byDay[key] or {}
		table.insert(byDay[key], entry)
	end

	for key, entries in byDay do
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(key, function(existing: { Entry }?)
				local list = existing or {}
				for _, entry in entries do
					table.insert(list, entry)
				end
				while #list > DAY_ENTRY_CAP do
					table.remove(list, 1)
				end
				return list
			end)
		end)
		if not ok then
			warn(`[AuditLogService] Flush failed for {key}: {err}. Will retry.`)
			for _, entry in entries do
				table.insert(pending, entry)
			end
		end
	end
end

local function matches(entry: Entry, query: Query): boolean
	if query.actorUserId and entry.actor ~= query.actorUserId then
		return false
	end
	if query.targetUserId and entry.target ~= query.targetUserId then
		return false
	end
	if query.action and entry.action ~= query.action then
		return false
	end
	return true
end

-- Newest first.
function AuditLogService:Query(query: Query?): { Entry }
	local q: Query = query or {}
	local limit = math.clamp(q.limit or 50, 1, 200)
	local days = math.clamp(q.days or 1, 1, 30)
	local seen: { [string]: boolean } = {}
	local results: { Entry } = {}

	local function consider(list: { Entry })
		for i = #list, 1, -1 do
			local entry = list[i]
			if not seen[entry.id] then
				seen[entry.id] = true
				if matches(entry, q) then
					table.insert(results, entry)
				end
			end
		end
	end

	consider(recent)
	if store ~= nil then
		local now = os.time()
		for d = 0, days - 1 do
			local ok, list = pcall((store :: DataStore).GetAsync, store, dayKey(now - d * 86400))
			if ok and type(list) == "table" then
				consider(list)
			end
		end
	end

	table.sort(results, function(a, b)
		return a.at > b.at
	end)
	while #results > limit do
		table.remove(results)
	end
	return results
end

function AuditLogService:Init()
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, StaffConfig.DataStores.AuditLog)
	if ok then
		store = result
	else
		warn(`[AuditLogService] DataStore unavailable ({result}); audit entries are kept in memory only.`)
	end
end

function AuditLogService:Start()
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			AuditLogService:Flush()
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() and store == nil then
			return
		end
		AuditLogService:Flush()
	end)
end

return AuditLogService
