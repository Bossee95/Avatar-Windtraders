--!strict
--[[
	Net: thin, validated wrapper around RemoteEvents and RemoteFunctions.

	Server:
		Net.OnEvent(name, function(player, ...) end, opts?)
		Net.OnInvoke(name, function(player, ...) return ... end, opts?)
		Net.Fire(name, player, ...)
		Net.FireAll(name, ...)
		Net.FireList(name, players, ...)
		-- opts = { rateLimit = callsPerSecond (default 10), validate = function(...) -> boolean }

	Client:
		Net.Fire(name, ...)
		Net.Invoke(name, ...)
		Net.OnEvent(name, function(...) end)

	Every name must be declared in Net/Remotes.luau or in a *Remotes module
	under Shared (see buildRegistry below). The server is
	authoritative: requests over the rate limit or failing `validate` are
	dropped (an invoke returns nil), and handler errors are caught and logged.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Core remotes live in Net/Remotes.luau. Every other system declares its own
-- in a ModuleScript anywhere under Shared whose name ends in "Remotes"
-- (e.g. Shared/Combat/CombatRemotes.luau) returning { Events = {...},
-- Functions = {...} }. They are merged here, so no system has to edit
-- another's file.
local function buildRegistry()
	local registry = { Events = {}, Functions = {} }
	local function merge(source: any, from: string)
		for _, kind in { "Events", "Functions" } do
			for name, enabled in (source and source[kind]) or {} do
				if enabled then
					local other = if kind == "Events" then "Functions" else "Events"
					assert(
						not registry[other][name],
						string.format("Net: '%s' (from %s) is both an Event and a Function", name, from)
					)
					registry[kind][name] = true
				end
			end
		end
	end
	merge(require(script.Remotes), "Net/Remotes")
	local shared = script.Parent
	for _, module in shared:GetDescendants() do
		if
			module:IsA("ModuleScript")
			and module ~= script.Remotes
			and string.sub(module.Name, -7) == "Remotes"
		then
			merge(require(module), module:GetFullName())
		end
	end
	return registry
end

local Registry = buildRegistry()

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "Remotes"
local DEFAULT_RATE_LIMIT = 10 -- calls per second per player per remote

export type Options = {
	rateLimit: number?,
	validate: ((...any) -> boolean)?,
}

local Net = {}

local folder: Folder

local function getFolder(): Folder
	if folder then
		return folder
	end
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			folder = existing :: Folder
		else
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end
	return folder
end

local function getRemote(name: string, kind: "Events" | "Functions"): Instance
	assert(
		Registry[kind][name],
		string.format("Net: '%s' is not registered under %s in any *Remotes module", name, kind)
	)
	local className = if kind == "Events" then "RemoteEvent" else "RemoteFunction"
	local parent = getFolder()
	local remote = parent:FindFirstChild(name)
	if remote then
		return remote
	end
	if IS_SERVER then
		local created = Instance.new(className)
		created.Name = name
		created.Parent = parent
		return created
	end
	local waited = parent:WaitForChild(name, 30)
	assert(waited, "Net: timed out waiting for remote " .. name)
	return waited
end

-- Creates every registered remote. Called once by the server's Main script so
-- clients never wait on a remote that is created lazily.
function Net.CreateAll()
	assert(IS_SERVER, "Net.CreateAll is server-only")
	for name in Registry.Events do
		getRemote(name, "Events")
	end
	for name in Registry.Functions do
		getRemote(name, "Functions")
	end
end

-- Per-player, per-remote token bucket.
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}

local function allow(player: Player, name: string, rate: number): boolean
	local playerBuckets = buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end
	local now = os.clock()
	local bucket = playerBuckets[name]
	if not bucket then
		bucket = { tokens = rate, last = now }
		playerBuckets[name] = bucket
	end
	bucket.tokens = math.min(rate, bucket.tokens + (now - bucket.last) * rate)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

local function guard(name: string, opts: Options?, player: Player, ...: any): boolean
	local rate = (opts and opts.rateLimit) or DEFAULT_RATE_LIMIT
	if not allow(player, name, rate) then
		return false
	end
	if opts and opts.validate then
		local ok, valid = pcall(opts.validate, ...)
		if not ok or valid ~= true then
			return false
		end
	end
	return true
end

function Net.OnEvent(name: string, handler: (...any) -> (), opts: Options?)
	local remote = getRemote(name, "Events") :: RemoteEvent
	if IS_SERVER then
		return remote.OnServerEvent:Connect(function(player, ...)
			if not guard(name, opts, player, ...) then
				return
			end
			local ok, err = pcall(handler, player, ...)
			if not ok then
				warn(string.format("[Net] %s handler error: %s", name, tostring(err)))
			end
		end)
	else
		return remote.OnClientEvent:Connect(handler)
	end
end

function Net.OnInvoke(name: string, handler: (Player, ...any) -> ...any, opts: Options?)
	assert(IS_SERVER, "Net.OnInvoke is server-only (the server never invokes clients)")
	local remote = getRemote(name, "Functions") :: RemoteFunction
	remote.OnServerInvoke = function(player, ...)
		if not guard(name, opts, player, ...) then
			return nil
		end
		local results = table.pack(pcall(handler, player, ...))
		if not results[1] then
			warn(string.format("[Net] %s handler error: %s", name, tostring(results[2])))
			return nil
		end
		return table.unpack(results, 2, results.n)
	end
end

function Net.Fire(name: string, ...: any)
	local remote = getRemote(name, "Events") :: RemoteEvent
	if IS_SERVER then
		local player = ...
		assert(
			typeof(player) == "Instance" and player:IsA("Player"),
			"Net.Fire on the server needs a Player first"
		)
		remote:FireClient(...)
	else
		remote:FireServer(...)
	end
end

function Net.FireAll(name: string, ...: any)
	assert(IS_SERVER, "Net.FireAll is server-only")
	local remote = getRemote(name, "Events") :: RemoteEvent
	remote:FireAllClients(...)
end

function Net.FireList(name: string, players: { Player }, ...: any)
	assert(IS_SERVER, "Net.FireList is server-only")
	local remote = getRemote(name, "Events") :: RemoteEvent
	for _, player in players do
		remote:FireClient(player, ...)
	end
end

function Net.Invoke(name: string, ...: any): ...any
	assert(not IS_SERVER, "Net.Invoke is client-only")
	local remote = getRemote(name, "Functions") :: RemoteFunction
	return remote:InvokeServer(...)
end

return Net
