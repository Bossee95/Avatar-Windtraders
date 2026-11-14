--!strict
--[[
	Pure combat rules shared by server and client.

	Nothing here touches the DataModel, so it can be unit tested. The server
	is the only authority: the client uses these functions only to grey out
	inputs it knows the server will reject.

	"record" below is the active Character from CharacterService (only the
	kits and abilities fields are read):
	  kits      = { [weaponType] = { level = number } }
	  abilities = { [abilityId] = { source = string } }
]]

local Config = script.Parent.Config
local Actions = require(Config.Actions)
local Kits = require(Config.Kits)
local Variations = require(Config.Variations)
local WeaponTypes = require(Config.WeaponTypes)
local GAbilities = require(Config.GAbilities)
local CombatSettings = require(Config.CombatSettings)
local Classes = require(Config.Classes)

local CombatRules = {}

export type Record = {
	kits: { [string]: { level: number } }?,
	abilities: { [string]: any }?,
}

export type State = {
	combatTagged: boolean?,
	busy: boolean?,
	stunned: boolean?,
	dead: boolean?,
}

export type Loadout = {
	variationId: string?,
	gAbilityId: string?,
}

CombatRules.Inputs = table.freeze({ "M1", "Z", "X", "C", "R", "G" })
local INPUT_SET = { M1 = true, Z = true, X = true, C = true, R = true, G = true }

function CombatRules.isInput(input: any): boolean
	return type(input) == "string" and INPUT_SET[input] == true
end

-- The kit level the Loreteam has granted this character for a weapon type,
-- or nil when the weapon type is not approved.
function CombatRules.getKitLevel(record: Record?, weaponType: string): number?
	if not record or not record.kits then
		return nil
	end
	local entry = record.kits[weaponType]
	if type(entry) ~= "table" or type(entry.level) ~= "number" or entry.level < 1 then
		return nil
	end
	return entry.level
end

-- The kit definition to use for a granted level: the exact level if
-- defined, otherwise the highest defined level below it.
function CombatRules.resolveKit(weaponType: string, level: number?): (Kits.Kit?, number?)
	local levels = Kits[weaponType]
	if not levels or not level then
		return nil, nil
	end
	local best: number? = nil
	for defined in levels do
		if defined <= level and (best == nil or defined > best) then
			best = defined
		end
	end
	if best == nil then
		return nil, nil
	end
	return levels[best], best
end

-- Returns the first state that blocks switching weapon / G ability, or nil.
function CombatRules.switchBlockReason(state: State?): string?
	if not state then
		return nil
	end
	local blocked = CombatSettings.SwitchBlockedWhen
	if state.dead and blocked.Dead then
		return "Dead"
	end
	if state.combatTagged and blocked.CombatTagged then
		return "InCombat"
	end
	if state.stunned and blocked.Stunned then
		return "Stunned"
	end
	if state.busy and blocked.Busy then
		return "Busy"
	end
	return nil
end

-- GDD §16.5: kit assigned, weapon type approved, variation valid, one
-- weapon at a time (equipping replaces), no switching in combat.
-- ownsVariation is whether the character holds this weapon item.
function CombatRules.canEquip(
	record: Record?,
	variationId: any,
	ownsVariation: boolean,
	state: State?,
	currentVariationId: string?,
	classId: string?
): (boolean, string?)
	if type(variationId) ~= "string" then
		return false, "InvalidVariation"
	end
	local variation = Variations[variationId]
	if not variation then
		return false, "InvalidVariation"
	end
	if currentVariationId == variationId then
		return false, "AlreadyEquipped"
	end
	-- A class locks the character to one weapon type.
	if classId ~= nil and CombatRules.classWeaponType(classId) ~= variation.weaponType then
		return false, "WrongClass"
	end
	if not ownsVariation then
		return false, "NotOwned"
	end
	local level = CombatRules.getKitLevel(record, variation.weaponType)
	if not level then
		return false, "KitNotAssigned"
	end
	if not CombatRules.resolveKit(variation.weaponType, level) then
		return false, "KitNotDefined"
	end
	local blocked = CombatRules.switchBlockReason(state)
	if blocked then
		return false, blocked
	end
	return true, nil
end

-- The weapon type a class is locked to, or nil for an unknown class.
function CombatRules.classWeaponType(classId: string?): string?
	local class = classId and Classes[classId]
	return class and class.weaponType
end

-- The class to use: the stored one if valid, otherwise the default.
function CombatRules.resolveClass(classId: any): string
	if type(classId) == "string" and Classes[classId] then
		return classId
	end
	return CombatSettings.DefaultClass
end

-- Which variation a class-locked character wields: the first owned
-- variation of the class's weapon type (sorted by id, so it is stable),
-- else the class's default. `owns` answers ownership per variation id.
function CombatRules.pickClassWeapon(classId: string, owns: (string) -> boolean): (string?, boolean)
	local class = Classes[classId]
	if not class then
		return nil, false
	end
	local candidates = {}
	for id, variation in Variations do
		if variation.weaponType == class.weaponType then
			table.insert(candidates, id)
		end
	end
	table.sort(candidates)
	for _, id in candidates do
		if owns(id) then
			return id, true
		end
	end
	return class.defaultVariation, false
end

function CombatRules.canUnequip(state: State?): (boolean, string?)
	local blocked = CombatRules.switchBlockReason(state)
	if blocked and blocked ~= "Dead" then
		return false, blocked
	end
	return true, nil
end

function CombatRules.hasGAbility(record: Record?, abilityId: string): boolean
	return record ~= nil
		and record.abilities ~= nil
		and record.abilities[abilityId] ~= nil
		and GAbilities[abilityId] ~= nil
end

function CombatRules.canSelectGAbility(record: Record?, abilityId: any, state: State?): (boolean, string?)
	if abilityId == nil then
		local blocked = CombatRules.switchBlockReason(state)
		if blocked then
			return false, blocked
		end
		return true, nil
	end
	if type(abilityId) ~= "string" or not GAbilities[abilityId] then
		return false, "InvalidAbility"
	end
	if not CombatRules.hasGAbility(record, abilityId) then
		return false, "AbilityNotAssigned"
	end
	local blocked = CombatRules.switchBlockReason(state)
	if blocked then
		return false, blocked
	end
	return true, nil
end

-- If the character has exactly one G ability, that one is used without
-- needing a selection.
function CombatRules.defaultGAbility(record: Record?): string?
	if not record or not record.abilities then
		return nil
	end
	local found: string? = nil
	for id in record.abilities do
		if GAbilities[id] then
			if found then
				return nil
			end
			found = id
		end
	end
	return found
end

-- Next M1 step (1-based) given the previous step and when the previous
-- action finished.
function CombatRules.nextComboIndex(
	weaponType: string,
	lastIndex: number?,
	lastEndTime: number?,
	now: number
): number
	local def = WeaponTypes[weaponType]
	if not def or not lastIndex or not lastEndTime then
		return 1
	end
	if now - lastEndTime > def.comboResetTime then
		return 1
	end
	if lastIndex >= #def.m1Combo then
		return 1
	end
	return lastIndex + 1
end

-- Maps an input to the action id it performs for this loadout, re-checking
-- permissions on every use so a revoked kit or ability stops working at once.
function CombatRules.resolveAction(
	record: Record?,
	loadout: Loadout,
	input: string,
	comboIndex: number?
): (string?, string?)
	if not CombatRules.isInput(input) then
		return nil, "InvalidInput"
	end

	if input == "G" then
		local abilityId = loadout.gAbilityId or CombatRules.defaultGAbility(record)
		if not abilityId then
			return nil, "NoGAbility"
		end
		if not CombatRules.hasGAbility(record, abilityId) then
			return nil, "AbilityNotAssigned"
		end
		local ability = GAbilities[abilityId]
		local variation = loadout.variationId and Variations[loadout.variationId]
		if ability.requiresWeapon and not variation then
			return nil, "NoWeapon"
		end
		if ability.allowedWeaponTypes then
			if not variation or not table.find(ability.allowedWeaponTypes, variation.weaponType) then
				return nil, "WrongWeaponType"
			end
		end
		return ability.action, nil
	end

	local variation = loadout.variationId and Variations[loadout.variationId]
	if not variation then
		return nil, "NoWeapon"
	end
	local weaponType = variation.weaponType
	local level = CombatRules.getKitLevel(record, weaponType)
	if not level then
		return nil, "KitNotAssigned"
	end

	if input == "M1" then
		local combo = WeaponTypes[weaponType].m1Combo
		local index = comboIndex or 1
		if index < 1 or index > #combo then
			index = 1
		end
		return combo[index], nil
	elseif input == "R" then
		return variation.critical, nil
	end

	local kit = CombatRules.resolveKit(weaponType, level)
	if not kit then
		return nil, "KitNotDefined"
	end
	local actionId = (kit.abilities :: any)[input]
	if not actionId then
		return nil, "SlotLocked"
	end
	return actionId, nil
end

-- Damage multiplier for distance-based falloff on ranged actions.
function CombatRules.falloffMultiplier(action: Actions.Action, distance: number): number
	local f = action.falloff
	if not f then
		return 1
	end
	if distance <= f.startRange then
		return 1
	end
	if distance >= f.endRange then
		return f.minMultiplier
	end
	local alpha = (distance - f.startRange) / (f.endRange - f.startRange)
	return 1 + (f.minMultiplier - 1) * alpha
end

-- Total time an action locks its user (windup, repeated hits, recovery).
function CombatRules.actionDuration(action: Actions.Action): number
	local hits = action.hits or 1
	return action.windup + (hits - 1) * (action.hitInterval or 0) + action.recovery
end

return CombatRules
