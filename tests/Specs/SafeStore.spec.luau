local ServerScriptService = game:GetService("ServerScriptService")
local Data = ServerScriptService.Server.Data
local SafeStore = require(Data.SafeStore)
local MockDataStore = require(Data.MockDataStore)

local function newStore(mock, clock)
	return SafeStore.new(mock, {
		lockTimeout = 300,
		loadLockRetries = 1,
		loadLockRetryDelay = 0,
		requestRetries = 3,
		requestRetryBaseDelay = 0,
		now = function()
			return clock.now
		end,
		wait = function() end,
	})
end

local function default()
	return { coins = 0 }
end

return function(t)
	t.test("load creates a default record and save persists it", function()
		local mock, clock = MockDataStore.new(), { now = 1000 }
		local store = newStore(mock, clock)
		local session = store:Load("k", { defaultFactory = default })
		t.expect(session).toBeTruthy()
		session.data.coins = 7
		t.expect((store:Save(session, true))).toBe(true)
		t.expect(mock:Peek("k").data.coins).toBe(7)
		t.expect(mock:Peek("k").meta.lock).toBeNil()
	end)

	t.test("a second server can't load a locked record", function()
		local mock, clock = MockDataStore.new(), { now = 1000 }
		local a, b = newStore(mock, clock), newStore(mock, clock)
		t.expect(a:Load("k", { defaultFactory = default })).toBeTruthy()
		local session, err = b:Load("k", { defaultFactory = default })
		t.expect(session).toBeNil()
		t.expect(err).toBe("Locked")
	end)

	t.test("a stale lock is taken over and the old session can no longer save", function()
		local mock, clock = MockDataStore.new(), { now = 1000 }
		local a, b = newStore(mock, clock), newStore(mock, clock)
		local old = a:Load("k", { defaultFactory = default })
		clock.now += 301
		local new = b:Load("k", { defaultFactory = default })
		t.expect(new).toBeTruthy()
		old.data.coins = 999
		local ok, err = a:Save(old, false)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("SessionLost")
		t.expect(mock:Peek("k").data.coins).toBe(0)
	end)

	t.test("missing record without a factory is NotFound and writes nothing", function()
		local mock, clock = MockDataStore.new(), { now = 1000 }
		local session, err = newStore(mock, clock):Load("missing", {})
		t.expect(session).toBeNil()
		t.expect(err).toBe("NotFound")
		t.expect(mock:Peek("missing")).toBeNil()
	end)

	t.test("transient errors are retried", function()
		local mock, clock = MockDataStore.new(), { now = 1000 }
		mock:FailNext(2)
		local session = newStore(mock, clock):Load("k", { defaultFactory = default })
		t.expect(session).toBeTruthy()
	end)

	t.test("discard releases the lock without writing", function()
		local mock, clock = MockDataStore.new(), { now = 1000 }
		local store = newStore(mock, clock)
		local first = store:Load("k", { defaultFactory = default })
		store:Save(first, true)
		local session = store:Load("k", {})
		session.data.coins = 50
		store:Discard(session)
		t.expect(mock:Peek("k").data.coins).toBe(0)
		t.expect(mock:Peek("k").meta.lock).toBeNil()
	end)
end
