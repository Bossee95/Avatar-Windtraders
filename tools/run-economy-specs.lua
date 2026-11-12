--[[
	Runs the economy specs (tests/Economy/*.spec.luau) outside Roblox Studio, with a
	plain Lua 5.4 interpreter:

		lua5.4 tools/run-economy-specs.lua

	The economy engines are pure Lua, so this gives fast feedback without Studio. The
	Studio runner (tests/Runner.server.luau) runs the same specs inside the game.

	This shim provides just enough of Roblox for the specs: `game:GetService()` returns
	path proxies for ServerScriptService.Server, ReplicatedStorage.Shared and
	ServerScriptService.Tests, `script` works inside modules, and `require` takes a proxy.
]]

local ROOTS = {
	ServerScriptService = { Server = "src/server", Tests = "tests" },
	ReplicatedStorage = { Shared = "src/shared" },
}

local cache = {}
local loadModule

local function proxy(path)
	return setmetatable({ __path = path }, {
		__index = function(self, key)
			if key == "Parent" then
				return proxy((self.__path:gsub("/[^/]+$", "")))
			end
			return proxy(self.__path .. "/" .. key)
		end,
	})
end

local function fileFor(path)
	for _, candidate in ipairs({ path .. ".luau", path .. ".lua", path .. "/init.luau", path .. "/init.lua" }) do
		local f = io.open(candidate, "r")
		if f then
			f:close()
			return candidate
		end
	end
	error("module not found: " .. path, 3)
end

local game = {
	GetService = function(_, name)
		local roots = ROOTS[name]
		assert(roots, "service not shimmed: " .. tostring(name))
		return setmetatable({}, {
			__index = function(_, key)
				return proxy(assert(roots[key], name .. "." .. key .. " not shimmed"))
			end,
		})
	end,
}

local function makeEnv(modulePath)
	local env = setmetatable({}, { __index = _G })
	env.game = game
	env.script = proxy(modulePath)
	env.require = function(target)
		if type(target) == "table" and target.__path then
			return loadModule(target.__path)
		end
		return require(target)
	end
	env.warn = function(...)
		print("WARN:", ...)
	end
	return env
end

function loadModule(path)
	if cache[path] ~= nil then
		return cache[path]
	end
	local file = fileFor(path)
	local chunk, err = loadfile(file, "t", makeEnv(path))
	assert(chunk, err)
	local result = chunk()
	cache[path] = result
	return result
end

-- Minimal version of the Studio runner's `t` API.
local function deepEqual(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function show(v)
	if type(v) ~= "table" then
		return tostring(v)
	end
	local parts = {}
	for k, x in pairs(v) do
		table.insert(parts, tostring(k) .. "=" .. show(x))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function expect(actual)
	return {
		toBe = function(expected)
			if actual ~= expected then
				error(("expected %s, got %s"):format(show(expected), show(actual)), 2)
			end
		end,
		toEqual = function(expected)
			if not deepEqual(actual, expected) then
				error(("expected %s, got %s"):format(show(expected), show(actual)), 2)
			end
		end,
		toBeNil = function()
			if actual ~= nil then
				error(("expected nil, got %s"):format(show(actual)), 2)
			end
		end,
		toBeTruthy = function()
			if not actual then
				error(("expected truthy, got %s"):format(show(actual)), 2)
			end
		end,
		toThrow = function()
			if pcall(actual) then
				error("expected function to throw", 2)
			end
		end,
	}
end

local specs = {}
local listing = io.popen('ls tests/Economy/*.spec.luau 2>/dev/null')
for line in listing:lines() do
	table.insert(specs, (line:gsub("%.luau$", "")))
end
listing:close()

local passed, failed = 0, 0
for _, path in ipairs(specs) do
	local spec = loadModule(path)
	spec({
		test = function(name, fn)
			local ok, err = pcall(fn)
			if ok then
				passed = passed + 1
			else
				failed = failed + 1
				print(("FAIL %s > %s\n     %s"):format(path, name, tostring(err)))
			end
		end,
		expect = expect,
	})
end
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
