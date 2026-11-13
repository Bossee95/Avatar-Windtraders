--!strict
-- Closed-community access gate (GDD §15.1).
--
-- On join, resolves the player's staff roles and checks access. Players who
-- fail are kicked, and DataService never loads their account (load guard).
-- Other systems can wait on AccessGateService:WaitForAdmission(player) or
-- check IsAllowed.
--
--   AccessGateService:IsAllowed(player)                 -> boolean
--   AccessGateService:WaitForAdmission(player)          -> boolean (yields until decided)
--   AccessGateService:AddToWhitelist(actor, userId, note?)  -> (ok, err)   [ManageAccess]
--   AccessGateService:RemoveFromWhitelist(actor, userId, note?) -> (ok, err) [ManageAccess]
--   AccessGateService:IsWhitelisted(userId)             -> boolean
--   AccessGateService.Admitted  signal-like: :Connect(fn(player))

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local AuditLogService = require(script.Parent.AuditLogService)
local StaffConfig = require(script.Parent.StaffConfig)
local StaffService = require(script.Parent.StaffService)

local AccessGateService = {}

AccessGateService.Admitted = Signal.new()

local whitelistStore: DataStore? = nil
-- userId -> true (admitted) | false (rejected); nil while undecided
local decisions: { [number]: boolean } = {}
local decided = Signal.new()

local function readWhitelist(userId: number): boolean
	if table.find(StaffConfig.Access.StaticWhitelist, userId) then
		return true
	end
	if whitelistStore == nil then
		return false
	end
	for attempt = 1, 3 do
		local ok, value = pcall((whitelistStore :: DataStore).GetAsync, whitelistStore, tostring(userId))
		if ok then
			return type(value) == "table" and value.allowed == true
		end
		task.wait(attempt)
	end
	-- Fail closed: if we cannot read the whitelist, do not admit.
	warn(`[AccessGateService] Whitelist read failed for {userId}`)
	return false
end

function AccessGateService:IsWhitelisted(userId: number): boolean
	return readWhitelist(userId)
end

local function evaluate(player: Player): boolean
	local roles, groupRank = StaffService:ResolveRoles(player)
	StaffService:SetRoles(player, roles)

	if not StaffConfig.Access.Enabled then
		return true
	end
	if StaffConfig.Access.AllowInStudio and RunService:IsStudio() then
		return true
	end
	if #roles > 0 then
		return true
	end
	local minRank = StaffConfig.Access.MinGroupRank
	if StaffConfig.GroupId ~= 0 and minRank > 0 and groupRank >= minRank then
		return true
	end
	return readWhitelist(player.UserId)
end

local function onPlayerAdded(player: Player)
	local allowed = evaluate(player)
	if player.Parent == nil then
		-- Left while being checked; release anything waiting on the decision.
		decided:Fire(player, false)
		return
	end
	decisions[player.UserId] = allowed
	player:SetAttribute("Admitted", allowed)
	decided:Fire(player, allowed)
	if allowed then
		AccessGateService.Admitted:Fire(player)
	else
		player:Kick(StaffConfig.Access.KickMessage)
	end
end

function AccessGateService:IsAllowed(player: Player): boolean
	return decisions[player.UserId] == true
end

function AccessGateService:WaitForAdmission(player: Player): boolean
	while decisions[player.UserId] == nil and player.Parent ~= nil do
		local who, allowed = decided:Wait()
		if who == player then
			return allowed
		end
	end
	return decisions[player.UserId] == true
end

local function setWhitelisted(actor: Player, userId: number, allowed: boolean, note: string?): (boolean, string?)
	local ok, err = StaffService:Require(actor, Permissions.Permission.ManageAccess)
	if not ok then
		return false, err
	end
	if type(userId) ~= "number" or userId <= 0 or userId % 1 ~= 0 then
		return false, "That is not a valid user id."
	end
	if whitelistStore == nil then
		return false, "The whitelist DataStore is unavailable. Use StaticWhitelist in StaffConfig instead."
	end
	local saved, saveErr = pcall(function()
		(whitelistStore :: DataStore):SetAsync(tostring(userId), {
			allowed = allowed,
			by = actor.UserId,
			at = os.time(),
			note = note and string.sub(note, 1, 200) or nil,
		})
	end)
	if not saved then
		return false, `Could not save the whitelist: {saveErr}`
	end
	AuditLogService:Record(actor.UserId, if allowed then "Access.Whitelist" else "Access.Unwhitelist", userId, { note = note })

	if not allowed then
		local target = Players:GetPlayerByUserId(userId)
		if target and #StaffService:GetRoles(target) == 0 then
			decisions[userId] = false
			target:Kick(StaffConfig.Access.KickMessage)
		end
	end
	return true, nil
end

function AccessGateService:AddToWhitelist(actor: Player, userId: number, note: string?): (boolean, string?)
	return setWhitelisted(actor, userId, true, note)
end

function AccessGateService:RemoveFromWhitelist(actor: Player, userId: number, note: string?): (boolean, string?)
	return setWhitelisted(actor, userId, false, note)
end

function AccessGateService:Init()
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, StaffConfig.DataStores.Whitelist)
	if ok then
		whitelistStore = result
	else
		warn(`[AccessGateService] Whitelist DataStore unavailable: {result}`)
	end

	-- Accounts of players who are not admitted are never loaded or locked.
	local DataService = require(script.Parent.Parent.DataService)
	DataService:RegisterLoadGuard("AccessGate", function(player: Player)
		return AccessGateService:WaitForAdmission(player)
	end)
end

function AccessGateService:Start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		decisions[player.UserId] = nil
	end)
end

return AccessGateService
