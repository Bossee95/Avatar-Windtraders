--!strict
--[[
	DataService: loads, holds and saves one session-locked record per account.

	See docs/CORE_API.md §5. In short:
	  - other systems keep their data in sections (RegisterSection in :Init);
	  - Character sections are wiped on Permanent Death, Account sections never;
	  - an account that can't be loaded safely kicks the player instead of
	    handing out a blank profile.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local GameConfig = require(Shared.Config.GameConfig)

local Data = script.Parent.Parent.Data
local SafeStore = require(Data.SafeStore)
local MockDataStore = require(Data.MockDataStore)
local Schema = require(Data.Schema)

local Config = GameConfig.Data

local DataService = {}

DataService.AccountLoaded = Signal.new() -- (player, account)
DataService.AccountReleasing = Signal.new() -- (player, account) just before the final save

local store: any = nil
local storeReady = Signal.new()
local started = false
local usingMock = false

local sessions: { [number]: any } = {} -- userId -> SafeStore session
local loading: { [number]: boolean } = {}
local releasing: { [number]: boolean } = {}
local loadFailed: { [number]: boolean } = {}
local offline: { [number]: boolean } = {} -- accounts locked here for an offline edit
local loadGuards: { { name: string, fn: (Player) -> boolean } } = {}
local playersByUserId: { [number]: Player } = {}

local function key(userId: number): string
	return Config.KeyPrefix .. tostring(userId)
end

local function makeStore(dataStore: any)
	return SafeStore.new(dataStore, {
		lockTimeout = Config.LockTimeout,
		loadLockRetries = Config.LoadLockRetries,
		loadLockRetryDelay = Config.LoadLockRetryDelay,
		requestRetries = Config.RequestRetries,
		requestRetryBaseDelay = Config.RequestRetryBaseDelay,
	})
end

local function resolveStore()
	if RunService:IsStudio() and Config.MockInStudioWithoutApiAccess then
		-- GetDataStore itself throws in an unpublished place file, so probe both.
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(Config.StoreName):GetAsync("__probe")
		end)
		if not ok then
			warn(
				"[DataService] DataStores unavailable in Studio ("
					.. tostring(err)
					.. "). Using an in-memory store; nothing will persist."
			)
			usingMock = true
			return makeStore(MockDataStore.new())
		end
	end
	return makeStore(DataStoreService:GetDataStore(Config.StoreName))
end

local function waitForStore()
	if not store then
		storeReady:Wait()
	end
end

------------------------------------------------------------------------
-- Sections
------------------------------------------------------------------------

function DataService:RegisterSection(name: string, definition: { scope: string, default: { [any]: any } })
	assert(not started, "DataService:RegisterSection must be called from a service's :Init()")
	Schema.registerSection(name, definition :: any)
end

--[[
	fn(player) -> boolean, may yield. Every guard must return true before a
	player's account is loaded (and locked); otherwise it is never loaded.
	The access gate uses this so players who aren't admitted never take a
	session lock.
]]
function DataService:RegisterLoadGuard(name: string, fn: (Player) -> boolean)
	assert(not started, "DataService:RegisterLoadGuard must be called from a service's :Init()")
	table.insert(loadGuards, { name = name, fn = fn })
end

------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------

function DataService:GetAccount(player: Player): any?
	local session = sessions[player.UserId]
	return if session and not session.lost then session.data else nil
end

function DataService:WaitForAccount(player: Player, timeout: number?): any?
	local deadline = os.clock() + (timeout or 30)
	while player.Parent and os.clock() < deadline do
		local account = DataService:GetAccount(player)
		if account then
			return account
		end
		if loadFailed[player.UserId] then
			return nil
		end
		task.wait(0.1)
	end
	return nil
end

function DataService:GetAccountByUserId(userId: number): any?
	local session = sessions[userId]
	return if session and not session.lost then session.data else nil
end

function DataService:GetPlayer(userId: number): Player?
	return playersByUserId[userId]
end

function DataService:IsLoaded(userId: number): boolean
	return DataService:GetAccountByUserId(userId) ~= nil
end

function DataService:IsUsingMockStore(): boolean
	return usingMock
end

function DataService:GetAccountSection(player: Player, name: string): any?
	local definition = Schema.getSection(name)
	assert(definition and definition.scope == "Account", "Not an Account-scope section: " .. name)
	local account = DataService:GetAccount(player)
	return account and account.sections[name]
end

function DataService:GetCharacterSection(player: Player, name: string, characterId: string?): any?
	local definition = Schema.getSection(name)
	assert(definition and definition.scope == "Character", "Not a Character-scope section: " .. name)
	local account = DataService:GetAccount(player)
	if not account then
		return nil
	end
	local id = characterId or account.activeCharacterId
	local character = id and account.characters[id]
	if not character or character.status ~= "Alive" then
		return nil
	end
	return character.sections[name]
end

------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------

function DataService:SaveNow(player: Player): boolean
	return DataService:SaveUserId(player.UserId)
end

function DataService:SaveUserId(userId: number): boolean
	local session = sessions[userId]
	if not session or releasing[userId] then
		return false
	end
	local ok, err = store:Save(session, false)
	if not ok and err == "SessionLost" then
		DataService:_onSessionLost(userId)
	end
	return ok
end

--[[
	Runs `fn(account)` on an account whether or not its player is in this
	server, and saves the result.

	  - Loaded here: runs on the live copy, then saves.
	  - Not loaded anywhere: locks the stored record on this server, runs `fn`
	    once, saves and releases. The player can't join this server until it
	    finishes.
	  - Held by another server: fails with "LockedByOtherServer".

	`fn` may yield. It can return `false, reason` to reject the change: an
	offline record is then released without saving (a live record is left as
	`fn` left it, so validate before mutating). Returns (ok, err) where err is
	the reason from `fn`, "NotFound", "LockedByOtherServer", "RequestFailed" or
	"EditFailed: <error>".
]]
function DataService:UpdateOffline(userId: number, fn: (any) -> (boolean?, string?)): (boolean, string?)
	waitForStore()

	-- Serialise with player loads and other offline edits of the same account.
	while loading[userId] or releasing[userId] or offline[userId] do
		task.wait(0.1)
	end

	local account = DataService:GetAccountByUserId(userId)
	if account then
		local ok, result, reason = pcall(fn, account)
		if not ok then
			return false, "EditFailed: " .. tostring(result)
		end
		if result == false then
			return false, reason
		end
		task.spawn(DataService.SaveUserId, DataService, userId)
		return true, nil
	end

	offline[userId] = true
	local session, loadErr = store:Load(key(userId), { lockRetries = 0 })
	if not session then
		offline[userId] = nil
		return false, if loadErr == "Locked" then "LockedByOtherServer" else loadErr
	end

	local prepared, prepareErr = pcall(Schema.prepare, session.data)
	if not prepared then
		store:Discard(session)
		offline[userId] = nil
		return false, "EditFailed: " .. tostring(prepareErr)
	end

	local ok, result, reason = pcall(fn, session.data)
	local saveOk, saveErr
	if ok and result ~= false then
		saveOk, saveErr = store:Save(session, true)
	else
		store:Discard(session)
	end
	offline[userId] = nil

	if not ok then
		return false, "EditFailed: " .. tostring(result)
	end
	if result == false then
		return false, reason
	end
	if not saveOk then
		return false, saveErr
	end
	return true, nil
end

-- Reads an account without locking it (staff review). Returns (ok, account?).
function DataService:PeekOffline(userId: number): (boolean, any?)
	waitForStore()
	local account = DataService:GetAccountByUserId(userId)
	if account then
		return true, account
	end
	local ok, data = store:Peek(key(userId))
	if ok and data then
		Schema.prepare(data)
	end
	return ok, data
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function DataService:_onSessionLost(userId: number)
	sessions[userId] = nil
	local player = playersByUserId[userId]
	if player and player.Parent then
		player:Kick("Your data was opened on another server. Please rejoin.")
	end
end

local function passesLoadGuards(player: Player): boolean
	for _, guard in loadGuards do
		local ok, allowed = pcall(guard.fn, player)
		if not ok then
			warn(string.format("[DataService] Load guard '%s' errored: %s", guard.name, tostring(allowed)))
			return false
		end
		if allowed ~= true then
			return false
		end
	end
	return true
end

local function loadPlayer(player: Player)
	local userId = player.UserId
	waitForStore()

	if not passesLoadGuards(player) then
		loadFailed[userId] = true
		return
	end

	-- A previous session of this player, or a staff edit of their offline
	-- record, may still be running in this server.
	while releasing[userId] or offline[userId] do
		task.wait(0.1)
	end
	if not player.Parent or sessions[userId] or loading[userId] then
		return
	end

	loading[userId] = true
	loadFailed[userId] = nil
	playersByUserId[userId] = player
	local session, err = store:Load(key(userId), {
		defaultFactory = function()
			return Schema.newAccount(userId, os.time())
		end,
		-- Safe: this server holds no session for the player (checked above).
		takeOverSameServer = true,
	})
	loading[userId] = nil

	if not session then
		if player.Parent then
			local message = if err == "Locked"
				then "Your data is still open on another server. Please wait a minute and rejoin."
				else "Your data couldn't be loaded. Please rejoin shortly."
			player:Kick(message)
		end
		loadFailed[userId] = true
		playersByUserId[userId] = nil
		return
	end

	local ok, prepareErr = pcall(Schema.prepare, session.data)
	if not ok then
		-- Never hand out (or save over) a record we couldn't understand.
		warn("[DataService] Couldn't prepare account " .. userId .. ": " .. tostring(prepareErr))
		store:Discard(session)
		player:Kick("Your data couldn't be loaded. Please contact staff.")
		loadFailed[userId] = true
		playersByUserId[userId] = nil
		return
	end

	if not player.Parent then
		-- Left while loading: release straight away.
		store:Save(session, true)
		playersByUserId[userId] = nil
		return
	end

	sessions[userId] = session
	DataService.AccountLoaded:Fire(player, session.data)
end

local function releasePlayer(player: Player)
	local userId = player.UserId
	local session = sessions[userId]
	if not session or releasing[userId] then
		return
	end
	releasing[userId] = true
	DataService.AccountReleasing:Fire(player, session.data)
	-- Signal handlers run in their own threads; give them a frame to finish.
	task.wait()
	store:Save(session, true)
	sessions[userId] = nil
	playersByUserId[userId] = nil
	releasing[userId] = nil
end

function DataService:Init()
	-- Nothing to do: sections are registered by other services' :Init().
end

function DataService:Start()
	started = true
	store = resolveStore()
	storeReady:Fire()

	Players.PlayerAdded:Connect(loadPlayer)
	Players.PlayerRemoving:Connect(releasePlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	task.spawn(function()
		while true do
			task.wait(Config.AutosaveInterval)
			for userId in sessions do
				task.spawn(DataService.SaveUserId, DataService, userId)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		loadFailed[player.UserId] = nil
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(releasePlayer, player)
		end
		-- Sessions are removed once their final save finishes (including ones
		-- PlayerRemoving already started).
		local deadline = os.clock() + 25
		while
			(next(sessions) ~= nil or next(loading) ~= nil or next(offline) ~= nil)
			and os.clock() < deadline
		do
			task.wait(0.1)
		end
	end)
end

return DataService
