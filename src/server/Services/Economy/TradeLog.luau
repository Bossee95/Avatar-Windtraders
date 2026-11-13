--[[
	TradeLog

	Records of item movements between players, for moderator disputes and
	investigations (GDD §8.5, §16.2, §16.4).

	Every trade is logged once it closes, whether it completed, was cancelled, declined
	or expired. Death satchel events (created, looted, cleared) go in the same log so
	moderators can follow an item from one owner to the next.

	Entry fields:
		id          string
		kind        "Trade" | "SatchelCreated" | "SatchelLoot" | "SatchelCleared"
		status      Trade: "Completed" | "Cancelled" | "Declined" | "Expired"
		            others: "Completed"
		reason      string? why a trade was cancelled, e.g. "PlayerCancelled", "PDPaused"
		time        number  time the entry was written (os.time() on Roblox)
		pdEventId   string?
		players     array of UserIds involved (used for filtering)
		parties     Trade: { { userId, characterId, offered = { {itemId, quantity, uid} } } x2 }
		items       Satchel entries: array of { itemId, quantity, uid? }
		satchelId   string?
		cancelledBy number? UserId

	The in-memory buffer covers this server. Pass a sink to persist entries (see
	TradeLogService), so moderators can query across servers and sessions.
]]

local TradeLog = {}
TradeLog.__index = TradeLog

local function warn_(msg)
	if warn then
		warn(msg)
	else
		print("WARN: " .. msg)
	end
end

--[[
	deps:
		now       function(): number
		newId     function(): string
		sink      function(entry)?   called for every entry, e.g. to write a DataStore
		limit     number?            in-memory entries kept (oldest dropped first)
]]
function TradeLog.new(deps)
	deps = deps or {}
	local counter = 0
	return setmetatable({
		_now = deps.now or os.time,
		_newId = deps.newId or function()
			counter = counter + 1
			return "log-" .. counter
		end,
		_sink = deps.sink,
		_limit = deps.limit or 2000,
		_entries = {},
	}, TradeLog)
end

function TradeLog:Record(entry)
	entry.id = entry.id or self._newId()
	entry.time = entry.time or self._now()
	table.insert(self._entries, entry)
	while #self._entries > self._limit do
		table.remove(self._entries, 1)
	end
	if self._sink then
		-- A failing sink must never break a trade that has already been applied.
		local ok, err = pcall(self._sink, entry)
		if not ok then
			warn_(("TradeLog sink failed for %s: %s"):format(entry.id, tostring(err)))
		end
	end
	return entry
end

local function involves(entry, userId)
	for _, id in ipairs(entry.players or {}) do
		if id == userId then
			return true
		end
	end
	return false
end

--[[
	filter (all optional):
		playerUserId  number   entries involving this player
		since, ["until"] number time range, inclusive
		status        string
		kind          string
		pdEventId     string
		itemId        string   entries that moved this item
		limit         number   newest first, default 100
	Returns entries newest first.
]]
function TradeLog:Query(filter)
	filter = filter or {}
	local limit = filter.limit or 100
	local untilTime = filter["until"]
	local out = {}
	for i = #self._entries, 1, -1 do
		local e = self._entries[i]
		local match = true
		if filter.playerUserId and not involves(e, filter.playerUserId) then
			match = false
		elseif filter.since and e.time < filter.since then
			match = false
		elseif untilTime and e.time > untilTime then
			match = false
		elseif filter.status and e.status ~= filter.status then
			match = false
		elseif filter.kind and e.kind ~= filter.kind then
			match = false
		elseif filter.pdEventId and e.pdEventId ~= filter.pdEventId then
			match = false
		elseif filter.itemId and not TradeLog.EntryMovesItem(e, filter.itemId) then
			match = false
		end
		if match then
			table.insert(out, e)
			if #out >= limit then
				break
			end
		end
	end
	return out
end

function TradeLog.EntryMovesItem(entry, itemId)
	for _, item in ipairs(entry.items or {}) do
		if item.itemId == itemId then
			return true
		end
	end
	for _, party in ipairs(entry.parties or {}) do
		for _, item in ipairs(party.offered or {}) do
			if item.itemId == itemId then
				return true
			end
		end
	end
	return false
end

return TradeLog
