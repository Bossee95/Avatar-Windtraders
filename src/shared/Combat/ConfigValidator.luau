--!strict
--[[
	Checks the combat config for broken references and bad values. The
	server runs it on start and refuses to enable combat if it fails, so a
	typo in a config file shows up immediately instead of mid-fight.

	Returns a list of problems (empty when valid).
]]

local Config = script.Parent.Config
local Actions = require(Config.Actions)
local Animations = require(Config.Animations)
local GAbilities = require(Config.GAbilities)
local Kits = require(Config.Kits)
local Variations = require(Config.Variations)
local WeaponTypes = require(Config.WeaponTypes)

local SHAPE_FIELDS = {
	Box = { "range", "width", "height" },
	Radius = { "radius" },
	Ray = { "range" },
	Cone = { "range", "angle" },
	None = {},
}
local TARGET_EFFECTS = { Knockback = "force", Stun = "duration" }
local SELF_EFFECTS = { SelfBuff = "duration", Smoke = "duration", SelfRoot = "duration" }

local ConfigValidator = {}

local function checkAction(problems: { string }, where: string, actionId: string?, kind: string)
	if actionId == nil then
		return
	end
	local action = Actions[actionId]
	if not action then
		table.insert(problems, `{where}: unknown action "{actionId}"`)
	elseif action.kind ~= kind then
		table.insert(problems, `{where}: action "{actionId}" has kind {action.kind}, expected {kind}`)
	end
end

function ConfigValidator.validate(): { string }
	local problems: { string } = {}

	for id, action in Actions do
		local where = `Actions.{id}`
		if type(action.displayName) ~= "string" then
			table.insert(problems, `{where}: missing displayName`)
		end
		for _, field in { "cooldown", "windup", "recovery" } do
			local v = (action :: any)[field]
			if type(v) ~= "number" or v < 0 then
				table.insert(problems, `{where}: {field} must be a number >= 0`)
			end
		end
		if action.kind ~= "M1" and action.cooldown <= 0 then
			table.insert(problems, `{where}: non-M1 actions need a cooldown > 0`)
		end
		local fields = SHAPE_FIELDS[action.hitbox and action.hitbox.shape]
		if not fields then
			table.insert(problems, `{where}: unknown hitbox shape`)
		else
			for _, field in fields do
				local v = (action.hitbox :: any)[field]
				if type(v) ~= "number" or v <= 0 then
					table.insert(problems, `{where}: hitbox.{field} must be > 0`)
				end
			end
			if action.hitbox.shape ~= "None" and (type(action.damage) ~= "number" or action.damage < 0) then
				table.insert(problems, `{where}: actions with a hitbox need damage >= 0`)
			end
		end
		if
			action.structureMultiplier ~= nil
			and (type(action.structureMultiplier) ~= "number" or action.structureMultiplier < 0)
		then
			table.insert(problems, `{where}: structureMultiplier must be a number >= 0`)
		end
		if action.hits and action.hits > 1 and not action.hitInterval then
			table.insert(problems, `{where}: hits > 1 needs hitInterval`)
		end
		if action.falloff and action.falloff.endRange <= action.falloff.startRange then
			table.insert(problems, `{where}: falloff.endRange must be > startRange`)
		end
		for _, e in action.effects or {} do
			local need = TARGET_EFFECTS[e.type]
			if not need then
				table.insert(problems, `{where}: effect {e.type} is not a target effect`)
			elseif type((e :: any)[need]) ~= "number" then
				table.insert(problems, `{where}: effect {e.type} needs {need}`)
			end
		end
		for _, e in action.selfEffects or {} do
			local need = SELF_EFFECTS[e.type]
			if not need then
				table.insert(problems, `{where}: effect {e.type} is not a self effect`)
			elseif type((e :: any)[need]) ~= "number" then
				table.insert(problems, `{where}: effect {e.type} needs {need}`)
			end
		end
		if Animations[action.animation] == nil then
			table.insert(problems, `{where}: unknown animation "{tostring(action.animation)}"`)
		end
	end

	for id, weaponType in WeaponTypes do
		if #weaponType.m1Combo == 0 then
			table.insert(problems, `WeaponTypes.{id}: empty m1Combo`)
		end
		for i, actionId in weaponType.m1Combo do
			checkAction(problems, `WeaponTypes.{id}.m1Combo[{i}]`, actionId, "M1")
		end
		if not Kits[id] then
			table.insert(problems, `WeaponTypes.{id}: no kits defined`)
		end
	end

	for weaponType, levels in Kits do
		if not WeaponTypes[weaponType] then
			table.insert(problems, `Kits.{weaponType}: unknown weapon type`)
		end
		for level, kit in levels do
			if type(level) ~= "number" or level < 1 or level % 1 ~= 0 then
				table.insert(problems, `Kits.{weaponType}: level keys must be whole numbers >= 1`)
				continue
			end
			for slot, actionId in kit.abilities :: any do
				if slot ~= "Z" and slot ~= "X" and slot ~= "C" then
					table.insert(problems, `Kits.{weaponType}[{level}]: unknown slot {slot}`)
				end
				checkAction(problems, `Kits.{weaponType}[{level}].{slot}`, actionId, "Kit")
			end
		end
	end

	for id, variation in Variations do
		if not WeaponTypes[variation.weaponType] then
			table.insert(problems, `Variations.{id}: unknown weapon type "{variation.weaponType}"`)
		end
		checkAction(problems, `Variations.{id}.critical`, variation.critical, "Critical")
	end

	for id, ability in GAbilities do
		checkAction(problems, `GAbilities.{id}.action`, ability.action, "G")
		for _, weaponType in ability.allowedWeaponTypes or {} do
			if not WeaponTypes[weaponType] then
				table.insert(problems, `GAbilities.{id}: unknown weapon type "{weaponType}"`)
			end
		end
	end

	table.sort(problems)
	return problems
end

return ConfigValidator
