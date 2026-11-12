--!strict
--[[
	Loader: starts every service (server) or controller (client).

	It requires every ModuleScript under `root` (subfolders included) whose name
	ends with `suffix`, then:
	  1. calls :Init() on each, in alphabetical order (must not yield);
	  2. calls :Start() on each, every one in its own thread.

	Modules with other names are helpers and are ignored, so they can sit next to
	their service. Other code can fetch a loaded module with Loader.Get(name).
]]

local Loader = {}

local modules: { [string]: any } = {}
local started = false

local function collect(root: Instance, suffix: string): { ModuleScript }
	local found = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ModuleScript") and string.sub(descendant.Name, -#suffix) == suffix then
			table.insert(found, descendant)
		end
	end
	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)
	return found
end

function Loader.Start(root: Instance, suffix: string)
	assert(not started, "Loader.Start was already called")
	started = true

	local ordered = {}
	for _, moduleScript in collect(root, suffix) do
		assert(modules[moduleScript.Name] == nil, "Duplicate module name: " .. moduleScript.Name)
		local ok, result = pcall(require, moduleScript)
		if not ok then
			error(string.format("[Loader] Failed to require %s: %s", moduleScript:GetFullName(), tostring(result)))
		end
		modules[moduleScript.Name] = result
		table.insert(ordered, { name = moduleScript.Name, module = result })
	end

	for _, entry in ordered do
		if type(entry.module) == "table" and type(entry.module.Init) == "function" then
			local thread = coroutine.create(entry.module.Init)
			local ok, err = coroutine.resume(thread, entry.module)
			if not ok then
				error(string.format("[Loader] %s:Init() failed: %s", entry.name, tostring(err)))
			end
			if coroutine.status(thread) ~= "dead" then
				error(string.format("[Loader] %s:Init() yielded; move yielding work to :Start()", entry.name))
			end
		end
	end

	for _, entry in ordered do
		if type(entry.module) == "table" and type(entry.module.Start) == "function" then
			task.spawn(function()
				local ok, err = pcall(entry.module.Start, entry.module)
				if not ok then
					warn(string.format("[Loader] %s:Start() failed: %s", entry.name, tostring(err)))
				end
			end)
		end
	end

	return modules
end

function Loader.Get(name: string): any
	local module = modules[name]
	assert(module ~= nil, "Loader.Get: no module named " .. name)
	return module
end

return Loader
