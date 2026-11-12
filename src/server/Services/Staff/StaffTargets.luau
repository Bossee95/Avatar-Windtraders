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

-- Uses the given character id, or the player's active character when they
-- are in this server.
function StaffTargets.ResolveCharacterId(CharacterService: any, userId: number, characterId: string?): (string?, string?)
	if characterId and characterId ~= "" then
		return characterId, nil
	end
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return nil, "That player is not in this server, so give the character id (e.g. 12345-2)."
	end
	local id = CharacterService:GetActiveCharacterId(player)
	if id == nil then
		return nil, "That player has no active character."
	end
	return id, nil
end

function StaffTargets.DisplayName(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return `{player.Name} ({userId})`
	end
	return tostring(userId)
end

return StaffTargets
