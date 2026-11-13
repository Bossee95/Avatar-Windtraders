--!strict
-- Combat remotes, merged into Shared.Net's registry. See docs/design/combat.md.
return {
	Events = {
		CombatUseAction = true, -- client -> server: input ("M1"/"Z"/"X"/"C"/"R"/"G"), aim: Vector3?
		CombatState = true, -- server -> client: { variationId, gAbilityId, inCombat, combatTagRemaining, cooldowns }
		CombatActionStarted = true, -- server -> all: character, actionId, input
		CombatHit = true, -- server -> all: character, actionId, { targets }
		CombatKnockback = true, -- server -> target: velocity
		CombatNotice = true, -- server -> client: kind, ... (rejections, forced unequip)
		CombatBlock = true, -- client -> server: raise (true) or lower (false) the block
		CombatDodge = true, -- client -> server: direction: Vector3 (horizontal, relative to the world)
		CombatDefenseState = true, -- server -> client: { blocking, blockCounts, maxBlock, dodgeCharges, maxDodge }
		CombatDefense = true, -- server -> all: character, kind ("BlockStart"/"BlockEnd"/"Blocked"/"PerfectBlock"/"BlockBroken"/"Dodge"/"Dodged"), extra?
	},
	Functions = {
		CombatEquip = true, -- variationId -> (ok, err)
		CombatUnequip = true, -- () -> (ok, err)
		CombatSelectGAbility = true, -- abilityId? -> (ok, err)
	},
}
