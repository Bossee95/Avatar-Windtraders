--!strict
--[[
	CharacterService: multiple characters per account, creation, selection
	and spawning. See docs/CORE_API.md §7.

	Players spawn only once a living character is selected. With no character
	selected they stay unspawned on the character screen.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)
local WorldConfig = require(Shared.Config.WorldConfig)
local GameConfig = require(Shared.Config.GameConfig)

local DataService = require(script.Parent.DataService)
local Schema = require(script.Parent.Parent.Data.Schema)
local Progression = require(script.Parent.Parent.Rules.Progression)

local Config = GameConfig.Characters

type Guard = { name: string, fn: (...any) -> (boolean, string?) }

local CharacterService = {}

CharacterService.CharacterSelected = Signal.new() -- (player, characterId?, previousId?)
CharacterService.CharacterChanged = Signal.new() -- (player?, userId, characterId, field)

local switchGuards: { Guard } = {}
local createGuards: { Guard } = {}

------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------

function CharacterService:GetActiveCharacterId(player: Player): string?
	local account = DataService:GetAccount(player)
	return account and account.activeCharacterId
end

function CharacterService:GetActiveCharacter(player: Player): any?
	local account = DataService:GetAccount(player)
	local id = account and account.activeCharacterId
	return id and account.characters[id]
end

function CharacterService:GetCharacter(player: Player, characterId: string): any?
	local account = DataService:GetAccount(player)
	return account and account.characters[characterId]
end

function CharacterService:ListCharacters(player: Player): { any }
	local account = DataService:GetAccount(player)
	local list = {}
	if account then
		for _, id in account.characterOrder do
			table.insert(list, account.characters[id])
		end
	end
	return list
end

function CharacterService:IsAlive(player: Player, characterId: string?): boolean
	local character = if characterId
		then CharacterService:GetCharacter(player, characterId)
		else CharacterService:GetActiveCharacter(player)
	return character ~= nil and character.status == "Alive"
end

local function countAlive(account: any): number
	local n = 0
	for _, character in account.characters do
		if character.status == "Alive" then
			n += 1
		end
	end
	return n
end

local function summarize(account: any)
	local characters = {}
	for _, id in account.characterOrder do
		local c = account.characters[id]
		table.insert(characters, {
			id = c.id,
			name = c.name,
			faction = c.faction,
			role = c.role,
			status = c.status,
			rank = c.rank,
		})
	end
	return {
		activeCharacterId = account.activeCharacterId,
		maxAliveCharacters = Config.MaxAliveCharacters,
		characters = characters,
	}
end

function CharacterService:GetState(player: Player): any?
	local account = DataService:GetAccount(player)
	return account and summarize(account)
end

function CharacterService:PushState(player: Player)
	local account = DataService:GetAccount(player)
	if account then
		Net.Fire("AccountState", player, summarize(account))
	end
end

------------------------------------------------------------------------
-- Guards
------------------------------------------------------------------------

-- fn(player, fromId?, toId?) -> (allowed, reason?). Any false blocks the switch.
function CharacterService:RegisterSwitchGuard(name: string, fn: (Player, string?, string?) -> (boolean, string?))
	table.insert(switchGuards, { name = name, fn = fn })
end

-- fn(player, { name, faction, role }) -> (allowed, reason?). Use for
-- recruitment limits and faction population balance (GDD §15.3).
function CharacterService:RegisterCreateGuard(name: string, fn: (Player, any) -> (boolean, string?))
	table.insert(createGuards, { name = name, fn = fn })
end

local function runGuards(guards: { Guard }, ...: any): (boolean, string?)
	for _, guard in guards do
		local ok, allowed, reason = pcall(guard.fn, ...)
		if not ok then
			warn(string.format("[CharacterService] Guard '%s' errored: %s", guard.name, tostring(allowed)))
			return false, "GuardError"
		end
		if allowed ~= true then
			return false, reason or ("BlockedBy:" .. guard.name)
		end
	end
	return true, nil
end

------------------------------------------------------------------------
-- Spawning
------------------------------------------------------------------------

local function despawn(player: Player)
	local model = player.Character
	if model then
		player.Character = nil
		model:Destroy()
	end
end

local function spawnActive(player: Player)
	if not player.Parent then
		return
	end
	if CharacterService:IsAlive(player) then
		player:LoadCharacter()
	else
		despawn(player)
	end
end

------------------------------------------------------------------------
-- Creating and selecting
------------------------------------------------------------------------

local function filterName(player: Player, name: string): (boolean, string?)
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(name, player.UserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		if RunService:IsStudio() then
			return true, nil -- the filter is unavailable in some Studio setups
		end
		return false, "NameFilterUnavailable"
	end
	if result ~= name then
		return false, "NameRejected"
	end
	return true, nil
end

local function validateName(name: any): (boolean, string?)
	if type(name) ~= "string" then
		return false, "InvalidName"
	end
	if utf8.len(name) == nil then
		return false, "InvalidName"
	end
	local length = utf8.len(name) :: number
	if length < Config.NameMinLength or length > Config.NameMaxLength then
		return false, "NameLength"
	end
	-- Letters, spaces, apostrophes and hyphens only; no leading/trailing space.
	if not string.match(name, "^[%a][%a '%-]*[%a]$") then
		return false, "InvalidName"
	end
	if string.find(name, "  ", 1, true) then
		return false, "InvalidName"
	end
	return true, nil
end

function CharacterService:CreateCharacter(player: Player, request: any): (boolean, string)
	local account = DataService:GetAccount(player)
	if not account then
		return false, "AccountNotLoaded"
	end
	if type(request) ~= "table" then
		return false, "InvalidRequest"
	end
	local name, faction = request.name, request.faction
	local role = request.role

	local ok, err = validateName(name)
	if not ok then
		return false, err :: string
	end
	if not WorldConfig.isValidFaction(faction) then
		return false, "InvalidFaction"
	end
	if not table.find(Config.PlayerSelectableFactions, faction) then
		-- Independent affiliations are assigned by staff (GDD §2.3).
		return false, "FactionNotSelectable"
	end
	if role == nil then
		role = WorldConfig.Factions[faction].defaultRole
	end
	if not WorldConfig.isValidRole(faction, role) then
		return false, "InvalidRole"
	end
	local leadership = WorldConfig.Factions[faction].roles[role].leadership
	if leadership then
		-- Leadership roles are entitlements granted by the Loreteam (GDD §13.2).
		return false, "RoleNotSelectable"
	end
	if countAlive(account) >= Config.MaxAliveCharacters then
		return false, "TooManyCharacters"
	end

	ok, err = runGuards(createGuards, player, { name = name, faction = faction, role = role })
	if not ok then
		return false, err :: string
	end

	-- Filtering yields; the account may have been released meanwhile.
	ok, err = filterName(player, name)
	if not ok then
		return false, err :: string
	end
	if DataService:GetAccount(player) ~= account then
		return false, "AccountNotLoaded"
	end
	if countAlive(account) >= Config.MaxAliveCharacters then
		return false, "TooManyCharacters"
	end

	local character = Schema.newCharacter(account, name, faction, role, os.time())
	account.nextCharacterSeq += 1
	account.characters[character.id] = character
	table.insert(account.characterOrder, character.id)
	Progression.appendLog(character, player.UserId, "Created", { faction = faction, role = role }, os.time())

	CharacterService.CharacterChanged:Fire(player, player.UserId, character.id, "Created")
	task.spawn(DataService.SaveNow, DataService, player)

	if account.activeCharacterId == nil then
		CharacterService:SelectCharacter(player, character.id)
	else
		CharacterService:PushState(player)
	end
	return true, character.id
end

function CharacterService:SelectCharacter(player: Player, characterId: any): (boolean, string?)
	local account = DataService:GetAccount(player)
	if not account then
		return false, "AccountNotLoaded"
	end
	if type(characterId) ~= "string" then
		return false, "InvalidCharacter"
	end
	local character = account.characters[characterId]
	if not character then
		return false, "InvalidCharacter"
	end
	if character.status ~= "Alive" then
		return false, "CharacterDead"
	end
	local previous = account.activeCharacterId
	if previous == characterId then
		return true, nil
	end
	local ok, err = runGuards(switchGuards, player, previous, characterId)
	if not ok then
		return false, err
	end

	account.activeCharacterId = characterId
	spawnActive(player)
	CharacterService.CharacterSelected:Fire(player, characterId, previous)
	CharacterService:PushState(player)
	return true, nil
end

function CharacterService:DeselectCharacter(player: Player): (boolean, string?)
	local account = DataService:GetAccount(player)
	if not account then
		return false, "AccountNotLoaded"
	end
	local previous = account.activeCharacterId
	if previous == nil then
		return true, nil
	end
	local ok, err = runGuards(switchGuards, player, previous, nil)
	if not ok then
		return false, err
	end
	account.activeCharacterId = nil
	despawn(player)
	CharacterService.CharacterSelected:Fire(player, nil, previous)
	CharacterService:PushState(player)
	return true, nil
end

------------------------------------------------------------------------
-- Internal: used by ProgressionService and PermadeathService
------------------------------------------------------------------------

function CharacterService:_notifyChanged(userId: number, characterId: string, field: string)
	local player = DataService:GetPlayer(userId)
	CharacterService.CharacterChanged:Fire(player, userId, characterId, field)
	if player then
		CharacterService:PushState(player)
	end
end

-- Called after Permanent Death cleared the active character.
function CharacterService:_onActiveCharacterLost(player: Player, characterId: string)
	despawn(player)
	CharacterService.CharacterSelected:Fire(player, nil, characterId)
	CharacterService:PushState(player)
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function CharacterService:Init()
	Players.CharacterAutoLoads = false
end

function CharacterService:Start()
	Net.OnInvoke("CreateCharacter", function(player, request)
		return CharacterService:CreateCharacter(player, request)
	end, { rateLimit = 1 })

	Net.OnInvoke("SelectCharacter", function(player, characterId)
		return CharacterService:SelectCharacter(player, characterId)
	end, {
		rateLimit = 2,
		validate = function(characterId)
			return type(characterId) == "string" and #characterId <= 32
		end,
	})

	Net.OnInvoke("GetAccountState", function(player)
		local account = DataService:WaitForAccount(player, 30)
		return account and summarize(account)
	end, { rateLimit = 2 })

	DataService.AccountLoaded:Connect(function(player, account)
		local active = account.activeCharacterId
		if active and not (account.characters[active] and account.characters[active].status == "Alive") then
			account.activeCharacterId = nil
			active = nil
		end
		CharacterService:PushState(player)
		if active then
			spawnActive(player)
			CharacterService.CharacterSelected:Fire(player, active, nil)
		end
	end)

	-- Ordinary (non-PD) deaths are not permanent: respawn the same character.
	local function onCharacterAdded(player: Player, model: Model)
		local humanoid = model:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then
			return
		end
		humanoid.Died:Connect(function()
			if not Config.RespawnAfterNonPermanentDeath then
				return
			end
			task.wait(Players.RespawnTime)
			if player.Parent and player.Character == model and CharacterService:IsAlive(player) then
				player:LoadCharacter()
			end
		end)
	end

	local function watch(player: Player)
		player.CharacterAdded:Connect(function(model)
			onCharacterAdded(player, model)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end

return CharacterService
