--!strict
--[[
	CharacterController: the client's view of the player's characters.

	Holds the latest account summary from the server and exposes requests for
	creating and selecting characters. A character-screen UI should read
	`CharacterController:GetState()` and listen to `StateChanged`.

	The server is authoritative: these requests can be refused, and the
	returned error string says why.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local CharacterController = {}

CharacterController.StateChanged = Signal.new() -- (state)

local state: any = nil

function CharacterController:GetState(): any
	return state
end

function CharacterController:GetActiveCharacter(): any?
	if not state or not state.activeCharacterId then
		return nil
	end
	for _, summary in state.characters do
		if summary.id == state.activeCharacterId then
			return summary
		end
	end
	return nil
end

-- request = { name: string, faction: string, role: string? } -> (ok, idOrError)
function CharacterController:CreateCharacter(request: { name: string, faction: string, role: string? }): (boolean, string?)
	local ok, result = Net.Invoke("CreateCharacter", request)
	if ok == nil then
		return false, "RequestDropped"
	end
	return ok, result
end

function CharacterController:SelectCharacter(characterId: string): (boolean, string?)
	local ok, err = Net.Invoke("SelectCharacter", characterId)
	if ok == nil then
		return false, "RequestDropped"
	end
	return ok, err
end

local function setState(newState: any)
	if newState then
		state = newState
		CharacterController.StateChanged:Fire(newState)
	end
end

function CharacterController:Start()
	Net.OnEvent("AccountState", setState)
	-- In case the first push arrived before we were listening.
	if not state then
		setState(Net.Invoke("GetAccountState"))
	end
end

return CharacterController
