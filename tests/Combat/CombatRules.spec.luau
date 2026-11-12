--!strict
-- Pure rule checks for weapon kits, variations, G abilities and switching
-- (GDD §5, §6, §16.5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Combat = ReplicatedStorage.Shared.Combat
local CombatRules = require(Combat.CombatRules)
local Variations = require(Combat.Config.Variations)
local WeaponTypes = require(Combat.Config.WeaponTypes)
local Kits = require(Combat.Config.Kits)

local function record(kits: { [string]: number }?, abilities: { string }?)
	local r = { kits = {}, abilities = {} }
	for weaponType, level in kits or {} do
		r.kits[weaponType] = { level = level, grantedBy = 1, at = 0 }
	end
	for _, id in abilities or {} do
		r.abilities[id] = { source = "Test", grantedBy = 1, at = 0 }
	end
	return r
end

return function(t)
	t.test("kit level comes only from the character record", function()
		t.expect(CombatRules.getKitLevel(record({ Sword = 2 }), "Sword")).toBe(2)
		t.expect(CombatRules.getKitLevel(record({ Sword = 2 }), "Spear")).toBeNil()
		t.expect(CombatRules.getKitLevel(nil, "Sword")).toBeNil()
		t.expect(CombatRules.getKitLevel(record({ Sword = 0 }), "Sword")).toBeNil()
	end)

	t.test("a level above the highest defined kit uses the highest defined", function()
		local kit, level = CombatRules.resolveKit("Sword", 7)
		t.expect(level).toBe(3)
		t.expect(kit).toBe(Kits.Sword[3])
	end)

	t.test("equip requires a kit for the weapon type", function()
		local ok, err = CombatRules.canEquip(record({ Spear = 3 }), "Sword_Standard", true, {}, nil)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("KitNotAssigned")
	end)

	t.test("owning a crafted weapon never grants its kit (§11.2)", function()
		local ok, err = CombatRules.canEquip(record({}), "Sword_Hooked", true, {}, nil)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("KitNotAssigned")
	end)

	t.test("equip requires owning the variation", function()
		local ok, err = CombatRules.canEquip(record({ Sword = 1 }), "Sword_Standard", false, {}, nil)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("NotOwned")
	end)

	t.test("equip rejects unknown variations and bad input", function()
		t.expect(select(2, CombatRules.canEquip(record({ Sword = 1 }), "Sword_Nope", true, {}, nil))).toBe("InvalidVariation")
		t.expect(select(2, CombatRules.canEquip(record({ Sword = 1 }), 42, true, {}, nil))).toBe("InvalidVariation")
	end)

	t.test("equip succeeds with kit, ownership and no blocking state", function()
		local ok, err = CombatRules.canEquip(record({ Sword = 1 }), "Sword_Standard", true, {}, nil)
		t.expect(ok).toBe(true)
		t.expect(err).toBeNil()
	end)

	t.test("one weapon at a time: re-equipping the same weapon is a no-op", function()
		local _, err = CombatRules.canEquip(record({ Sword = 1 }), "Sword_Standard", true, {}, "Sword_Standard")
		t.expect(err).toBe("AlreadyEquipped")
	end)

	t.test("switching is blocked in combat, mid-action, stunned and dead (§5.3, §19.5)", function()
		local r = record({ Sword = 1, Spear = 1 })
		t.expect(select(2, CombatRules.canEquip(r, "Spear_Standard", true, { combatTagged = true }, "Sword_Standard"))).toBe("InCombat")
		t.expect(select(2, CombatRules.canEquip(r, "Spear_Standard", true, { busy = true }, "Sword_Standard"))).toBe("Busy")
		t.expect(select(2, CombatRules.canEquip(r, "Spear_Standard", true, { stunned = true }, "Sword_Standard"))).toBe("Stunned")
		t.expect(select(2, CombatRules.canEquip(r, "Spear_Standard", true, { dead = true }, "Sword_Standard"))).toBe("Dead")
		t.expect(select(2, CombatRules.canUnequip({ combatTagged = true }))).toBe("InCombat")
		t.expect(CombatRules.canUnequip({})).toBe(true)
	end)

	t.test("every variation of a type shares the same M1 combo (§6.2)", function()
		local r = record({ Sword = 1 })
		for i = 1, #WeaponTypes.Sword.m1Combo do
			local a = CombatRules.resolveAction(r, { variationId = "Sword_Standard" }, "M1", i)
			local b = CombatRules.resolveAction(r, { variationId = "Sword_Hooked" }, "M1", i)
			t.expect(a).toBe(WeaponTypes.Sword.m1Combo[i])
			t.expect(b).toBe(a)
		end
	end)

	t.test("R is the variation's own Critical (§5.5)", function()
		local r = record({ Sword = 3 })
		local a = CombatRules.resolveAction(r, { variationId = "Sword_Standard" }, "R")
		local b = CombatRules.resolveAction(r, { variationId = "Sword_Hooked" }, "R")
		t.expect(a).toBe(Variations.Sword_Standard.critical)
		t.expect(b).toBe(Variations.Sword_Hooked.critical)
		t.expect(a == b).toBe(false)
	end)

	t.test("Z/X/C come from the kit level and unlock with it", function()
		local loadout = { variationId = "Spear_Standard" }
		t.expect(CombatRules.resolveAction(record({ Spear = 1 }), loadout, "Z")).toBe("Spear_Thrust")
		t.expect(select(2, CombatRules.resolveAction(record({ Spear = 1 }), loadout, "X"))).toBe("SlotLocked")
		t.expect(CombatRules.resolveAction(record({ Spear = 2 }), loadout, "X")).toBe("Spear_Spin")
		t.expect(CombatRules.resolveAction(record({ Spear = 3 }), loadout, "C")).toBe("Spear_VaultStrike")
	end)

	t.test("one rank, many kits: the same character can hold several weapon types (§4.3)", function()
		local r = record({ Sword = 3, Spear = 3, Bow = 3 })
		t.expect(CombatRules.resolveAction(r, { variationId = "Sword_Standard" }, "C")).toBe("Sword_HeavySlash")
		t.expect(CombatRules.resolveAction(r, { variationId = "Bow_Recurve" }, "C")).toBe("Bow_Volley")
	end)

	t.test("a revoked kit stops every weapon input immediately", function()
		local loadout = { variationId = "Sword_Standard" }
		for _, input in { "M1", "Z", "X", "C", "R" } do
			t.expect(select(2, CombatRules.resolveAction(record({}), loadout, input))).toBe("KitNotAssigned")
		end
	end)

	t.test("weapon inputs need an equipped weapon", function()
		t.expect(select(2, CombatRules.resolveAction(record({ Sword = 1 }), {}, "M1"))).toBe("NoWeapon")
	end)

	t.test("invalid inputs are rejected", function()
		t.expect(select(2, CombatRules.resolveAction(record({ Sword = 1 }), { variationId = "Sword_Standard" }, "Q"))).toBe("InvalidInput")
		t.expect(CombatRules.isInput(nil)).toBe(false)
	end)

	t.test("G needs an assigned ability and is separate from the kit (§6.5)", function()
		t.expect(select(2, CombatRules.resolveAction(record({}), {}, "G"))).toBe("NoGAbility")
		-- Usable with no kit and no weapon.
		t.expect(CombatRules.resolveAction(record({}, { "Grab" }), {}, "G")).toBe("G_Grab")
		-- With several, the selected one is used.
		local r = record({}, { "Grab", "SmokeGrenade" })
		t.expect(select(2, CombatRules.resolveAction(r, {}, "G"))).toBe("NoGAbility")
		t.expect(CombatRules.resolveAction(r, { gAbilityId = "SmokeGrenade" }, "G")).toBe("G_SmokeGrenade")
		-- A selection that is no longer assigned is rejected.
		t.expect(select(2, CombatRules.resolveAction(record({}, { "Grab" }), { gAbilityId = "SmokeGrenade" }, "G"))).toBe("AbilityNotAssigned")
	end)

	t.test("selecting a G ability is checked and blocked in combat", function()
		local r = record({}, { "Grab" })
		t.expect(CombatRules.canSelectGAbility(r, "Grab", {})).toBe(true)
		t.expect(select(2, CombatRules.canSelectGAbility(r, "BattleCry", {}))).toBe("AbilityNotAssigned")
		t.expect(select(2, CombatRules.canSelectGAbility(r, "Nope", {}))).toBe("InvalidAbility")
		t.expect(select(2, CombatRules.canSelectGAbility(r, "Grab", { combatTagged = true }))).toBe("InCombat")
	end)

	t.test("M1 combo advances, wraps and resets after the reset window", function()
		local reset = WeaponTypes.Sword.comboResetTime
		local steps = #WeaponTypes.Sword.m1Combo
		t.expect(CombatRules.nextComboIndex("Sword", nil, nil, 10)).toBe(1)
		t.expect(CombatRules.nextComboIndex("Sword", 1, 10, 10 + reset / 2)).toBe(2)
		t.expect(CombatRules.nextComboIndex("Sword", 1, 10, 10 + reset + 0.01)).toBe(1)
		t.expect(CombatRules.nextComboIndex("Sword", steps, 10, 10.1)).toBe(1)
	end)

	t.test("ranged falloff scales between start and end range", function()
		local action = { falloff = { startRange = 10, endRange = 20, minMultiplier = 0.5 } } :: any
		t.expect(CombatRules.falloffMultiplier(action, 5)).toBe(1)
		t.expect(CombatRules.falloffMultiplier(action, 15)).toBe(0.75)
		t.expect(CombatRules.falloffMultiplier(action, 50)).toBe(0.5)
		t.expect(CombatRules.falloffMultiplier({} :: any, 50)).toBe(1)
	end)
end
