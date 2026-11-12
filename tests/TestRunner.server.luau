--[[
	Minimal spec runner (only included by test.project.json).

	Every ModuleScript under Tests/Specs named *.spec returns function(t). Run
	the test place in Studio and read the Output window.

		t.test("name", function() ... end)
		t.expect(value).toBe(expected)       -- ==
		t.expect(value).toEqual(expected)    -- deep equality
		t.expect(value).toBeNil()
		t.expect(value).toBeTruthy()
		t.expect(fn).toThrow()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Table = require(ReplicatedStorage.Shared.Util.Table)

local function fmt(value: any): string
	if type(value) == "table" then
		local ok, encoded = pcall(function()
			return game:GetService("HttpService"):JSONEncode(value)
		end)
		return if ok then encoded else tostring(value)
	end
	return tostring(value)
end

local function expect(actual: any)
	local matchers = {}
	function matchers.toBe(expected: any)
		if actual ~= expected then
			error(string.format("expected %s, got %s", fmt(expected), fmt(actual)), 2)
		end
	end
	function matchers.toEqual(expected: any)
		if not Table.deepEqual(actual, expected) then
			error(string.format("expected %s, got %s", fmt(expected), fmt(actual)), 2)
		end
	end
	function matchers.toBeNil()
		if actual ~= nil then
			error(string.format("expected nil, got %s", fmt(actual)), 2)
		end
	end
	function matchers.toBeTruthy()
		if not actual then
			error(string.format("expected a truthy value, got %s", fmt(actual)), 2)
		end
	end
	function matchers.toThrow()
		local ok = pcall(actual)
		if ok then
			error("expected function to throw", 2)
		end
	end
	return matchers
end

local passed, failed = 0, 0
local failures = {}

for _, module in script.Parent.Specs:GetDescendants() do
	if module:IsA("ModuleScript") and string.match(module.Name, "%.spec$") then
		local ok, spec = pcall(require, module)
		if not ok then
			failed += 1
			table.insert(failures, module.Name .. " failed to load: " .. tostring(spec))
			continue
		end
		local t = {
			expect = expect,
			test = function(name: string, fn: () -> ())
				local testOk, err = pcall(fn)
				if testOk then
					passed += 1
				else
					failed += 1
					table.insert(failures, string.format("%s > %s: %s", module.Name, name, tostring(err)))
				end
			end,
		}
		local runOk, runErr = pcall(spec, t)
		if not runOk then
			failed += 1
			table.insert(failures, module.Name .. " errored: " .. tostring(runErr))
		end
	end
end

for _, failure in failures do
	warn("[Tests] FAIL " .. failure)
end
print(string.format("[Tests] %d passed, %d failed", passed, failed))
