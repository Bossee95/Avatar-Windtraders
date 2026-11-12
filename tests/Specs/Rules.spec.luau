local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Server = ServerScriptService.Server
local Schema = require(Server.Data.Schema)
local Progression = require(Server.Rules.Progression)
local Permadeath = require(Server.Rules.Permadeath)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local STAFF = 1
local NOW = 5000

-- Sections are global, so register the test ones once per run.
local function ensureSections()
	if not Schema.getSection("Test_Inventory") then
		Schema.registerSection("Test_Inventory", { scope = "Character", default = { items = {} } })
	end
	if not Schema.getSection("Test_Skins") then
		Schema.registerSection("Test_Skins", { scope = "Account", default = { owned = {} } })
	end
end

local function newAccountWithCharacter()
	ensureSections()
	local account = Schema.newAccount(42, NOW)
	local character = Schema.newCharacter(account, "Test Name", "FactionB", "Warrior", NOW)
	account.nextCharacterSeq += 1
	account.characters[character.id] = character
	table.insert(account.characterOrder, character.id)
	account.activeCharacterId = character.id
	return account, character
end

local function request(character, extra)
	local r = { userId = 42, characterId = character.id, pdEventId = "pd-1", confirmedBy = STAFF, reason = "test" }
	for k, v in extra or {} do
		r[k] = v
	end
	return r
end

return function(t)
	t.test("character ids are per account and sequential", function()
		local account, character = newAccountWithCharacter()
		t.expect(character.id).toBe("42-1")
		t.expect(Schema.newCharacter(account, "Other", "FactionA", "Military", NOW).id).toBe("42-2")
	end)

	t.test("trials must be approved in order when an order is configured", function()
		local _, character = newAccountWithCharacter()
		local faction = WorldConfig.Factions.FactionB
		local saved = faction.trials
		faction.trials = { "T1", "T2", "T3" }
		local ok, err = Progression.approveTrial(character, "T2", STAFF, NOW)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("OutOfOrder")
		t.expect((Progression.approveTrial(character, "T1", STAFF, NOW))).toBe(true)
		t.expect((Progression.approveTrial(character, "T2", STAFF, NOW))).toBe(true)
		t.expect(Progression.getNextTrial(character)).toBe("T3")
		local revoked
		ok, err, revoked = Progression.revokeTrial(character, "T1", STAFF, NOW)
		t.expect(ok).toBe(true)
		t.expect(revoked).toEqual({ "T1", "T2" })
		t.expect(#character.trials).toBe(0)
		faction.trials = saved
	end)

	t.test("kit level can't exceed overall rank", function()
		local _, character = newAccountWithCharacter()
		local ok, err = Progression.grantKit(character, "Spear", 3, STAFF, NOW)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("KitLevelAboveRank")
		Progression.setRank(character, 3, STAFF, NOW)
		t.expect((Progression.grantKit(character, "Spear", 3, STAFF, NOW))).toBe(true)
		t.expect((Progression.grantKit(character, "Bow", 3, STAFF, NOW))).toBe(true)
		t.expect(character.kits.Spear.level).toBe(3)
	end)

	t.test("permadeath resets progression, keeps account sections and history", function()
		local account, character = newAccountWithCharacter()
		Progression.setRank(character, 2, STAFF, NOW)
		Progression.grantKit(character, "Spear", 2, STAFF, NOW)
		Progression.grantAbility(character, "BattleCry", "Lore", STAFF, NOW)
		character.sections.Test_Inventory.items = { "knife" }
		account.sections.Test_Skins.owned = { "GoldSpear" }

		local moved
		local hooks = {
			{
				name = "Satchel",
				fn = function(ctx)
					moved = ctx.sections.Test_Inventory.items
					ctx.sections.Test_Inventory.items = {}
				end,
			},
		}
		local ok = Permadeath.process(account, request(character), hooks, NOW)
		t.expect(ok).toBe(true)
		t.expect(moved).toEqual({ "knife" })
		t.expect(character.status).toBe("Dead")
		t.expect(character.rank).toBe(0)
		t.expect(next(character.kits)).toBeNil()
		t.expect(next(character.abilities)).toBeNil()
		t.expect(next(character.sections)).toBeNil()
		t.expect(character.death.final.rank).toBe(2)
		t.expect(character.death.final.kits.Spear.level).toBe(2)
		t.expect(account.sections.Test_Skins.owned).toEqual({ "GoldSpear" })
		t.expect(account.activeCharacterId).toBeNil()
	end)

	t.test("permadeath is not applied twice", function()
		local account, character = newAccountWithCharacter()
		Permadeath.process(account, request(character), {}, NOW)
		local ok, err = Permadeath.process(account, request(character), {}, NOW)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("AlreadyDead")
	end)

	t.test("a failing hook rolls everything back", function()
		local account, character = newAccountWithCharacter()
		Progression.setRank(character, 4, STAFF, NOW)
		character.sections.Test_Inventory.items = { "bow" }
		local rolledBack = false
		local hooks = {
			{
				name = "First",
				fn = function(ctx)
					ctx.sections.Test_Inventory.items = {}
				end,
				rollback = function()
					rolledBack = true
				end,
			},
			{
				name = "Broken",
				fn = function()
					error("boom")
				end,
			},
		}
		local ok, err = Permadeath.process(account, request(character), hooks, NOW)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("HookFailed:Broken")
		t.expect(rolledBack).toBe(true)
		t.expect(character.status).toBe("Alive")
		t.expect(character.rank).toBe(4)
		t.expect(character.death).toBeNil()
		t.expect(character.sections.Test_Inventory.items).toEqual({ "bow" })
		t.expect(account.activeCharacterId).toBe(character.id)
	end)

	t.test("a yielding hook is rejected", function()
		local account, character = newAccountWithCharacter()
		local hooks = {
			{
				name = "Yields",
				fn = function()
					task.wait()
				end,
			},
		}
		local ok, err = Permadeath.process(account, request(character), hooks, NOW)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("HookFailed:Yields")
		t.expect(character.status).toBe("Alive")
	end)

	t.test("permadeath refuses another account's character", function()
		local account, character = newAccountWithCharacter()
		local ok, err = Permadeath.process(account, request(character, { userId = 7 }), {}, NOW)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("CharacterNotFound")
	end)
end
