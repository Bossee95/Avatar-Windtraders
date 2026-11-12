--!strict
--[[
	SafeStore: session-locked records on top of a GlobalDataStore.

	Each key holds { data = <record>, meta = { lock = Lock?, savedAt, saveCount } }.
	A session owns the lock from Load until Save(..., release = true). While
	another live session holds the lock, Load waits/retries and then fails,
	so two servers can never both write the same account (the classic
	duplication bug). A lock not refreshed within `lockTimeout`
	seconds is considered abandoned by a crashed server and may be taken over.

	Every write uses UpdateAsync and checks that this session still owns the
	lock. If it doesn't (the lock was taken over), the write is cancelled and
	the session is marked `lost`; the caller must stop using it and should kick
	the player.

	All DataStore calls are retried with exponential backoff.

		local store = SafeStore.new(dataStore, options)
		local session, err = store:Load(key, { defaultFactory = makeDefault })
		store:Save(session, false)            -- autosave, keeps the lock
		store:Save(session, true)             -- final save, releases the lock
		store:Peek(key)                       -- read without locking
]]

local HttpService = game:GetService("HttpService")

local Table = require(game:GetService("ReplicatedStorage").Shared.Util.Table)

export type Options = {
	lockTimeout: number,
	loadLockRetries: number,
	loadLockRetryDelay: number,
	requestRetries: number,
	requestRetryBaseDelay: number,
	now: (() -> number)?,
	wait: ((number) -> ())?,
}

export type Session = {
	key: string,
	id: string,
	data: any,
	lost: boolean,
	released: boolean,
	saving: boolean,
}

local SafeStore = {}
SafeStore.__index = SafeStore

function SafeStore.new(dataStore: any, options: Options)
	return setmetatable({
		_store = dataStore,
		_options = options,
		_now = options.now or os.time,
		_wait = options.wait or task.wait,
	}, SafeStore)
end

-- Runs `fn` with retries. Returns (ok, resultOrError).
function SafeStore:_request(label: string, fn: () -> any): (boolean, any)
	local options = self._options
	local delay = options.requestRetryBaseDelay
	local lastError
	for attempt = 1, options.requestRetries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		warn(
			string.format(
				"[SafeStore] %s failed (attempt %d/%d): %s",
				label,
				attempt,
				options.requestRetries,
				tostring(result)
			)
		)
		if attempt < options.requestRetries then
			self._wait(delay)
			delay *= 2
		end
	end
	return false, lastError
end

function SafeStore:_lockIsLive(lock: any, takeOverSameServer: boolean?): boolean
	if type(lock) ~= "table" then
		return false
	end
	-- A lock left by this very server (e.g. a release save that failed) can be
	-- reclaimed when the caller knows it holds no other session for the key.
	-- Studio has an empty JobId, so this never applies there.
	if takeOverSameServer and game.JobId ~= "" and lock.jobId == game.JobId then
		return false
	end
	return (self._now() - (lock.at or 0)) < self._options.lockTimeout
end

export type LoadOptions = {
	-- Builds a fresh record when the key is empty. Without it, an empty key
	-- fails with "NotFound" and nothing is written.
	defaultFactory: (() -> any)?,
	-- Reclaim a lock this same server left behind. Only pass true when this
	-- server is certain it holds no other session for the key.
	takeOverSameServer: boolean?,
	-- Overrides Options.loadLockRetries (0 = fail at once if locked).
	lockRetries: number?,
}

--[[
	Loads and locks `key`. Returns (session, nil) or
	(nil, "Locked" | "NotFound" | "RequestFailed").
]]
function SafeStore:Load(key: string, loadOptions: LoadOptions?): (Session?, string?)
	local sessionId = HttpService:GenerateGUID(false)
	local options = self._options
	local opts = loadOptions or {}
	local retries = opts.lockRetries or options.loadLockRetries

	for attempt = 1, retries + 1 do
		local outcome = "Locked"
		local ok, result = self:_request("Load " .. key, function()
			return self._store:UpdateAsync(key, function(old)
				local record = old
				if type(record) ~= "table" or type(record.meta) ~= "table" then
					record = { data = nil, meta = { saveCount = 0 } }
				end
				if self:_lockIsLive(record.meta.lock, opts.takeOverSameServer) then
					outcome = "Locked"
					return nil -- cancel: someone else holds it
				end
				if record.data == nil then
					if not opts.defaultFactory then
						outcome = "NotFound"
						return nil
					end
					record.data = opts.defaultFactory()
				end
				record.meta.lock = { sessionId = sessionId, jobId = game.JobId, at = self._now() }
				outcome = "Ok"
				return record
			end)
		end)

		if not ok then
			return nil, "RequestFailed"
		end
		if outcome == "Ok" then
			return {
				key = key,
				id = sessionId,
				data = result.data,
				lost = false,
				released = false,
				saving = false,
			},
				nil
		end
		if outcome == "NotFound" then
			return nil, "NotFound"
		end
		if attempt <= retries then
			self._wait(options.loadLockRetryDelay)
		end
	end
	return nil, "Locked"
end

--[[
	Writes the session's data. `release = true` also frees the lock; the
	session can't be used afterwards. Returns (ok, err) where err is
	"SessionLost" | "Released" | "RequestFailed".
]]
function SafeStore:Save(session: Session, release: boolean): (boolean, string?)
	if session.released then
		return false, "Released"
	end
	if session.lost then
		return false, "SessionLost"
	end

	-- Serialise concurrent saves of the same session (autosave racing a leave).
	while session.saving do
		self._wait(0.1)
	end
	if session.released then
		return false, "Released"
	end
	session.saving = true

	local lost = false
	local snapshot = Table.deepCopy(session.data)
	local ok = self:_request("Save " .. session.key, function()
		return self._store:UpdateAsync(session.key, function(old)
			if type(old) ~= "table" or type(old.meta) ~= "table" then
				lost = true
				return nil
			end
			local lock = old.meta.lock
			if type(lock) ~= "table" or lock.sessionId ~= session.id then
				lost = true
				return nil
			end
			lost = false
			old.data = snapshot
			old.meta.savedAt = self._now()
			old.meta.saveCount = (old.meta.saveCount or 0) + 1
			old.meta.lock = if release
				then nil
				else { sessionId = session.id, jobId = game.JobId, at = self._now() }
			return old
		end)
	end)

	session.saving = false
	if not ok then
		return false, "RequestFailed"
	end
	if lost then
		session.lost = true
		warn(
			string.format(
				"[SafeStore] Session for %s was taken over by another server; not saving.",
				session.key
			)
		)
		return false, "SessionLost"
	end
	if release then
		session.released = true
	end
	return true, nil
end

--[[
	Releases the lock without writing the session's data (used when an offline
	edit is rejected, so a half-made change is never stored).
]]
function SafeStore:Discard(session: Session): boolean
	if session.released or session.lost then
		return false
	end
	session.released = true
	local ok = self:_request("Discard " .. session.key, function()
		return self._store:UpdateAsync(session.key, function(old)
			if type(old) ~= "table" or type(old.meta) ~= "table" then
				return nil
			end
			local lock = old.meta.lock
			if type(lock) ~= "table" or lock.sessionId ~= session.id then
				return nil
			end
			old.meta.lock = nil
			return old
		end)
	end)
	return ok
end

-- Reads a record without locking it (for staff review of offline accounts).
function SafeStore:Peek(key: string): (boolean, any)
	local ok, result = self:_request("Peek " .. key, function()
		return self._store:GetAsync(key)
	end)
	if not ok then
		return false, nil
	end
	return true, if type(result) == "table" then result.data else nil
end

return SafeStore
