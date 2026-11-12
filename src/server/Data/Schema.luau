--!strict
--[[
	Schema: default records, section registry and migrations for accounts.

	Sections are how other systems store data without adding fields to the core
	records (see DataService:RegisterSection):
	  Account scope   -> account.sections[name]    survives Permanent Death
	  Character scope -> character.sections[name]  wiped on Permanent Death

	To change the record shape, bump CURRENT_VERSION and add a migration that
	upgrades from the previous version. Migrations run on load, in order.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Table = require(ReplicatedStorage.Shared.Util.Table)

export type Scope = "Account" | "Character"
export type SectionDefinition = { scope: Scope, default: { [any]: any } }

local Schema = {}

Schema.CURRENT_VERSION = 1

-- [fromVersion] = function(account) upgrades it to fromVersion + 1
local migrations: { [number]: (any) -> () } = {
	-- [1] = function(account) ... end,
}

local sections: { [string]: SectionDefinition } = {}

function Schema.registerSection(name: string, definition: SectionDefinition)
	assert(type(name) == "string" and #name > 0, "Section name must be a non-empty string")
	assert(definition.scope == "Account" or definition.scope == "Character", "Section scope must be Account or Character")
	assert(type(definition.default) == "table", "Section default must be a table")
	assert(sections[name] == nil, "Section already registered: " .. name)
	sections[name] = { scope = definition.scope, default = Table.deepCopy(definition.default) }
end

function Schema.getSection(name: string): SectionDefinition?
	return sections[name]
end

function Schema.getSections(): { [string]: SectionDefinition }
	return sections
end

-- For tests only.
function Schema._resetSections()
	table.clear(sections)
end

local function freshSections(scope: Scope): { [string]: any }
	local result = {}
	for name, definition in sections do
		if definition.scope == scope then
			result[name] = Table.deepCopy(definition.default)
		end
	end
	return result
end

function Schema.newAccount(userId: number, now: number)
	return {
		schemaVersion = Schema.CURRENT_VERSION,
		userId = userId,
		createdAt = now,
		activeCharacterId = nil,
		characterOrder = {},
		characters = {},
		nextCharacterSeq = 1,
		sections = freshSections("Account"),
	}
end

function Schema.newCharacter(account: any, name: string, faction: string, role: string, now: number)
	local seq = account.nextCharacterSeq
	return {
		id = string.format("%d-%d", account.userId, seq),
		userId = account.userId,
		name = name,
		faction = faction,
		role = role,
		status = "Alive",
		createdAt = now,
		rank = 0,
		trials = {},
		kits = {},
		abilities = {},
		sections = freshSections("Character"),
		log = {},
		death = nil,
	}
end

-- Empties every character-scope section (used by Permanent Death). A dead
-- character keeps no possessions, not even section defaults.
function Schema.clearCharacterSections(character: any)
	character.sections = {}
end

-- Runs migrations and fills in any newly registered sections. Returns the account.
function Schema.prepare(account: any)
	local version = account.schemaVersion or 1
	while version < Schema.CURRENT_VERSION do
		local migrate = migrations[version]
		assert(migrate, "Missing account migration from version " .. version)
		migrate(account)
		version += 1
	end
	account.schemaVersion = version

	account.sections = account.sections or {}
	account.characters = account.characters or {}
	account.characterOrder = account.characterOrder or {}

	for name, definition in sections do
		if definition.scope == "Account" then
			if account.sections[name] == nil then
				account.sections[name] = Table.deepCopy(definition.default)
			else
				Table.reconcile(account.sections[name], definition.default)
			end
		end
	end

	for _, character in account.characters do
		character.sections = character.sections or {}
		-- Dead characters stay empty; their sections were cleared at death.
		if character.status == "Alive" then
			for name, definition in sections do
				if definition.scope == "Character" then
					if character.sections[name] == nil then
						character.sections[name] = Table.deepCopy(definition.default)
					else
						Table.reconcile(character.sections[name], definition.default)
					end
				end
			end
		end
	end

	return account
end

return Schema
