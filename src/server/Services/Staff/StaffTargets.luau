--!strict
-- Resolves "who" and "which character" for staff tools. Helper, not a service.

local Players = game:GetService("Players")

local StaffTargets = {}

-- Accepts a user id ("12345"), an exact username, or a unique prefix of an
-- online player's name or display name. Offline usernames are looked up with
-- the Roblox API (yields).
function StaffTargets.ResolveUserId(text: string): (number?, string?)
	if type(text) ~= "string" or text == "" then
		return nil, "Name a player (username or user id)."
	end
	local asNumber = tonumber(text)
	if asNumber and asNumber > 0 and asNumber % 1 == 0 then
		return asNumber, nil
	end

	local lower = string.lower(text)
	local matches = {}
	for _, player in Players:GetPlayers() do
		local name, display = string.lower(player.Name), string.lower(player.DisplayName)
		if name == lower then
			return player.UserId, nil
		end
		if string.sub(name, 1, #lower) == lower or string.sub(display, 1, #lower) == lower then
			table.insert(matches, player)
		end
	end
	if #matches == 1 then
		return matches[1].UserId, nil
	elseif #matches > 1 then
		return nil, `"{text}" matches more than one player in this server. Type more of the name.`
	end

	local ok, userId = pcall(Players.GetUserIdFromNameAsync, Players, text)
	if ok and userId then
		return userId, nil
	end
	return nil, `No player called "{text}".`
end

-- Reads an account for review: the live copy if the player is in this
-- server, otherwise a read-only peek (yields).
function StaffTargets.PeekAccount(DataService: any, userId: number): (any?, string?)
	local ok, account = DataService:PeekOffline(userId)
	if not ok then
		return nil, "Could not read that player's data right now. Try again."
	end
	if account == nil then
		return nil, "That player has never joined."
	end
	return account, nil
end

-- Uses the given character id, or the target's active character (their
-- current one if online, or the last one they played if offline).
function StaffTargets.ResolveCharacterId(DataService: any, userId: number, characterId: string?): (string?, string?)
	if characterId and characterId ~= "" then
		return characterId, nil
	end
	local account, err = StaffTargets.PeekAccount(DataService, userId)
	if account == nil then
		return nil, err
	end
	local id = account.activeCharacterId
	if id == nil then
		return nil, "That player has no active character. Give one with char=<id>."
	end
	return id, nil
end

-- Returns the character record (read-only) for review.
function StaffTargets.GetCharacter(DataService: any, userId: number, characterId: string?): (any?, string?)
	local account, err = StaffTargets.PeekAccount(DataService, userId)
	if account == nil then
		return nil, err
	end
	local id = characterId or account.activeCharacterId
	local character = id and account.characters[id]
	if character == nil then
		return nil, if id then `No character {id} on that account.` else "That player has no active character."
	end
	return character, nil
end

function StaffTargets.DisplayName(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return `{player.Name} ({userId})`
	end
	return tostring(userId)
end

return StaffTargets
