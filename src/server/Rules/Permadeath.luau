--!strict
--[[
	Permanent Death rules (GDD §9.1, §16.3): a pure function over an account
	record, so it can be tested without players or DataStores.

	Permadeath.process(account, request, hooks, now) -> (ok, err)

	Steps 2 to 6 of §16.3 (step 1, confirmation, is the caller's job):
	  2. mark the character Dead and write its death record, including a
	     `final` snapshot of its progression (the historical record);
	  3. run each transfer hook (e.g. death satchels) with the live character
	     sections, before anything is wiped;
	  4. reset progression: rank, Trials, kits, G abilities, and empty every
	     character-scope section;
	  5. account-scope sections (weapon skins) are never touched;
	  6. clear the active character so the player picks or creates another.

	If a hook errors or yields, completed hooks are rolled back in reverse
	order and the character is restored exactly as it was, in place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Table = require(ReplicatedStorage.Shared.Util.Table)
local Schema = require(script.Parent.Parent.Data.Schema)
local Progression = require(script.Parent.Progression)

export type Request = {
	userId: number,
	characterId: string,
	pdEventId: string,
	confirmedBy: number,
	reason: string?,
	location: CFrame?,
	player: Player?,
}

export type Hook = {
	name: string,
	fn: (any) -> (),
	rollback: ((any) -> ())?,
}

local Permadeath = {}

-- Runs fn(ctx) and requires it to finish without yielding.
local function runNoYield(fn: (any) -> (), ctx: any): (boolean, string?)
	local thread = coroutine.create(fn)
	local ok, err = coroutine.resume(thread, ctx)
	if not ok then
		return false, tostring(err)
	end
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, "hook yielded; transfer hooks must not yield"
	end
	return true, nil
end

local function restoreInPlace(target: { [any]: any }, backup: { [any]: any })
	table.clear(target)
	for k, v in backup do
		target[k] = v
	end
end

function Permadeath.process(account: any, request: Request, hooks: { Hook }, now: number): (boolean, string?)
	local character = account.characters[request.characterId]
	if character == nil or character.userId ~= request.userId then
		return false, "CharacterNotFound"
	end
	if character.status == "Dead" then
		return false, "AlreadyDead"
	end

	local backup = Table.deepCopy(character)
	local backupActive = account.activeCharacterId

	-- 2. Mark dead and keep the historical record.
	character.status = "Dead"
	character.death = {
		at = now,
		pdEventId = request.pdEventId,
		confirmedBy = request.confirmedBy,
		reason = request.reason,
		final = {
			faction = character.faction,
			role = character.role,
			rank = character.rank,
			trials = Table.deepCopy(character.trials),
			kits = Table.deepCopy(character.kits),
			abilities = Table.deepCopy(character.abilities),
		},
	}

	-- 3. Transfer hooks, before anything is wiped.
	local ctx = {
		player = request.player,
		userId = request.userId,
		characterId = request.characterId,
		pdEventId = request.pdEventId,
		location = request.location,
		character = Table.deepFreeze(Table.deepCopy(character)),
		sections = character.sections,
	}

	local completed: { Hook } = {}
	for _, hook in hooks do
		local ok, err = runNoYield(hook.fn, ctx)
		if not ok then
			warn(
				string.format(
					"[Permadeath] Transfer hook '%s' failed for %s: %s",
					hook.name,
					request.characterId,
					tostring(err)
				)
			)
			for i = #completed, 1, -1 do
				local done = completed[i]
				if done.rollback then
					local rollbackOk, rollbackErr = runNoYield(done.rollback, ctx)
					if not rollbackOk then
						warn(
							string.format(
								"[Permadeath] Rollback of '%s' failed: %s",
								done.name,
								tostring(rollbackErr)
							)
						)
					end
				end
			end
			restoreInPlace(character, backup)
			account.activeCharacterId = backupActive
			return false, "HookFailed:" .. hook.name
		end
		table.insert(completed, hook)
	end

	-- 4. Reset character-bound progression and possessions.
	character.rank = 0
	character.trials = {}
	character.kits = {}
	character.abilities = {}
	Schema.clearCharacterSections(character)
	Progression.appendLog(character, request.confirmedBy, "Permadeath", {
		pdEventId = request.pdEventId,
		reason = request.reason,
	}, now)

	-- 6. The player must continue with another character.
	if account.activeCharacterId == request.characterId then
		account.activeCharacterId = nil
	end

	return true, nil
end

return Permadeath
