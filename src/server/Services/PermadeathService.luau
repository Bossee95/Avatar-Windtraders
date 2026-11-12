--!strict
--[[
	PermadeathService: the controlled Permanent Death sequence (GDD §16.3).
	See docs/CORE_API.md §9.

	The staff tools call ConfirmDeath after a moderator confirms a recognised
	death (step 1). This service does the rest: marks the character dead with
	its historical record, runs transfer hooks (death satchels), resets
	character-bound progression and possessions, keeps account-wide data
	(skins) untouched, saves, and returns the player to the character screen.

	Works for players who already left (e.g. combat logging): their record is
	locked on this server for the duration. Hooks then get `player = nil`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local DataService = require(script.Parent.DataService)
local CharacterService = require(script.Parent.CharacterService)
local Permadeath = require(script.Parent.Parent.Rules.Permadeath)

local PermadeathService = {}

-- (player?, userId, characterId, pdEventId), after the death is committed.
PermadeathService.Permadeath = Signal.new()

local hooks: { Permadeath.Hook } = {}
local processing: { [string]: boolean } = {}
local pdEventProvider: (() -> string?)? = nil

--[[
	fn() returns the id of the PD event that is active right now, or nil. The
	PD event service sets this in its :Init(). Until it is set, every death
	confirmation is refused.
]]
function PermadeathService:SetPdEventProvider(fn: () -> string?)
	pdEventProvider = fn
end

--[[
	Registers a step that runs after the character is marked dead and before
	its progression and character sections are wiped. `fn(ctx)` must not
	yield. If it errors, earlier hooks' `rollback(ctx)` run in reverse order
	and the character is restored, so only undo effects outside the record.

	ctx = { player: Player?, userId, characterId, pdEventId, location: CFrame?,
	        character (frozen copy), sections (live character sections) }
]]
function PermadeathService:RegisterTransferHook(name: string, fn: (any) -> (), options: { rollback: ((any) -> ())? }?)
	assert(type(name) == "string" and type(fn) == "function", "RegisterTransferHook(name, fn, options?)")
	for _, hook in hooks do
		assert(hook.name ~= name, "Transfer hook already registered: " .. name)
	end
	table.insert(hooks, { name = name, fn = fn, rollback = options and options.rollback })
end

local function validRequest(request: any): boolean
	return type(request) == "table"
		and type(request.userId) == "number"
		and type(request.characterId) == "string"
		and type(request.pdEventId) == "string"
		and type(request.confirmedBy) == "number"
		and (request.reason == nil or type(request.reason) == "string")
		and (request.location == nil or typeof(request.location) == "CFrame")
end

--[[
	request = { userId, characterId, pdEventId, confirmedBy, reason?, location? }
	Returns (ok, err). Errors: "InvalidRequest", "NoActivePd", "PdMismatch",
	"AlreadyProcessing", "CharacterNotFound", "AlreadyDead",
	"HookFailed:<name>", "LockedByOtherServer", "RequestFailed".
]]
function PermadeathService:ConfirmDeath(request: any): (boolean, string?)
	if not validRequest(request) then
		return false, "InvalidRequest"
	end
	local activePd = pdEventProvider and pdEventProvider()
	if activePd == nil then
		-- Only deaths in an officially recognised PD count (GDD §3.1).
		return false, "NoActivePd"
	end
	if activePd ~= request.pdEventId then
		return false, "PdMismatch"
	end
	if processing[request.characterId] then
		return false, "AlreadyProcessing"
	end

	processing[request.characterId] = true
	local player = DataService:GetPlayer(request.userId)
	local wasActive = false

	local ok, err = DataService:UpdateOffline(request.userId, function(account)
		wasActive = account.activeCharacterId == request.characterId
		return Permadeath.process(account, {
			userId = request.userId,
			characterId = request.characterId,
			pdEventId = request.pdEventId,
			confirmedBy = request.confirmedBy,
			reason = request.reason,
			location = request.location,
			player = player,
		}, hooks, os.time())
	end)
	processing[request.characterId] = nil

	if not ok then
		return false, err
	end

	-- Persist the death straight away rather than waiting for the autosave.
	-- (UpdateOffline already saved an offline record.)
	if player and DataService:GetAccount(player) then
		DataService:SaveNow(player)
		if wasActive then
			CharacterService:_onActiveCharacterLost(player, request.characterId)
		end
	end

	CharacterService:_notifyChanged(request.userId, request.characterId, "Status")
	PermadeathService.Permadeath:Fire(player, request.userId, request.characterId, request.pdEventId)
	return true, nil
end

return PermadeathService
