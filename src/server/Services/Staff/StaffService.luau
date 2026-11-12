--!strict
-- Resolves a player's staff roles and answers permission checks.
--
--   StaffService:HasPermission(player, permission) -> boolean
--   StaffService:Require(player, permission)       -> (ok, err)  for command handlers
--   StaffService:GetRoles(player)                  -> { string }
--   StaffService:IsStaff(player)                   -> boolean
--
-- Roles are resolved once on join (group rank lookups are web calls) and
-- cached as a player attribute "StaffRoles" so the client can show tools.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)
local StaffConfig = require(script.Parent.StaffConfig)

local StaffService = {}

local rolesByUserId: { [number]: { string } } = {}

local function addRole(list: { string }, role: string)
	if Permissions.IsValidRole(role) and not table.find(list, role) then
		table.insert(list, role)
	end
end

-- Group rank lookup with a retry; returns 0 on failure (fail closed).
local function getGroupRank(player: Player): number
	if StaffConfig.GroupId == 0 then
		return 0
	end
	for attempt = 1, 3 do
		local ok, rank = pcall(player.GetRankInGroup, player, StaffConfig.GroupId)
		if ok then
			return rank
		end
		task.wait(attempt)
	end
	warn(`[StaffService] Could not read group rank for {player.UserId}; treating as rank 0`)
	return 0
end

function StaffService:ResolveRoles(player: Player): ({ string }, number)
	local roles: { string } = {}
	local explicit = StaffConfig.UserRoles[player.UserId]
	if explicit then
		for _, role in explicit do
			addRole(roles, role)
		end
	end
	local rank = getGroupRank(player)
	-- Bootstrap: the place owner (user owner, or rank 255 of the owning group)
	-- is always Owner, so the game can be administered before config is filled in.
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		addRole(roles, Permissions.Role.Owner)
	elseif game.CreatorType == Enum.CreatorType.Group and StaffConfig.GroupId == game.CreatorId and rank == 255 then
		addRole(roles, Permissions.Role.Owner)
	end
	if StaffConfig.StudioOwner and RunService:IsStudio() then
		addRole(roles, Permissions.Role.Owner)
	end
	for _, entry in StaffConfig.GroupRankRoles do
		if rank >= entry.MinRank then
			addRole(roles, entry.Role)
		end
	end
	return roles, rank
end

-- Called by AccessGateService on join, so the group rank is only fetched once.
function StaffService:SetRoles(player: Player, roles: { string })
	rolesByUserId[player.UserId] = table.freeze(table.clone(roles))
	player:SetAttribute("StaffRoles", table.concat(roles, ","))
end

function StaffService:GetRoles(player: Player): { string }
	return rolesByUserId[player.UserId] or {}
end

function StaffService:GetRolesByUserId(userId: number): { string }
	return rolesByUserId[userId] or {}
end

function StaffService:IsStaff(player: Player): boolean
	return #StaffService:GetRoles(player) > 0
end

function StaffService:HasPermission(player: Player?, permission: string): boolean
	if player == nil then
		return false
	end
	return Permissions.RolesHave(StaffService:GetRoles(player), permission)
end

function StaffService:Require(player: Player?, permission: string): (boolean, string?)
	if StaffService:HasPermission(player, permission) then
		return true, nil
	end
	return false, `You do not have permission to do that ({permission}).`
end

function StaffService:Start()
	Players.PlayerRemoving:Connect(function(player)
		rolesByUserId[player.UserId] = nil
	end)
end

return StaffService
