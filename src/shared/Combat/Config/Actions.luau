--!strict
--[[
	Every combat action: M1 combo steps, kit abilities (Z/X/C), Critical
	attacks (R) and G abilities.

	All numbers here are placeholders for the Development Team to balance
	(GDD §6.1, §6.4, §6.5). The server reads them; clients never send
	damage, range or cooldown values.

	Fields
	  kind        "M1" | "Kit" | "Critical" | "G". Validated against where the
	              action is referenced.
	  cooldown    Seconds before this action can be used again. M1 steps use
	              0 and are paced by windup/recovery instead.
	  windup      Seconds from input to the hit check. Being stunned or dying
	              during windup cancels the action.
	  recovery    Seconds after the hit during which no other action can start.
	  hitbox      Where the server looks for targets (see HitDetection):
	                Box     range, width, height in front of the attacker
	                Radius  radius around the attacker
	                Ray     range along the aim direction, first target hit
	                Cone    range and full angle (degrees) around the aim
	                None    no targets (self-only actions)
	  maxTargets  Optional cap on how many targets one hit can damage.
	  damage      Base damage per hit.
	  hits        Optional number of repeated hit checks (default 1).
	  hitInterval Seconds between repeated hits.
	  falloff     Optional { startRange, endRange, minMultiplier } for ranged.
	  effects     Applied to each target hit (Knockback, Stun).
	  selfEffects Applied to the user (SelfBuff, Smoke, SelfRoot).
	  animation   Key in Animations.luau.
]]

export type Hitbox = {
	shape: "Box" | "Radius" | "Ray" | "Cone" | "None",
	range: number?,
	width: number?,
	height: number?,
	radius: number?,
	angle: number?,
}

export type Effect = {
	type: "Knockback" | "Stun" | "SelfBuff" | "Smoke" | "SelfRoot",
	force: number?,
	duration: number?,
	damageMultiplier: number?,
	radius: number?,
	distance: number?,
}

export type Action = {
	displayName: string,
	kind: "M1" | "Kit" | "Critical" | "G",
	cooldown: number,
	windup: number,
	recovery: number,
	hitbox: Hitbox,
	damage: number?,
	maxTargets: number?,
	hits: number?,
	hitInterval: number?,
	falloff: { startRange: number, endRange: number, minMultiplier: number }?,
	effects: { Effect }?,
	selfEffects: { Effect }?,
	animation: string,
}

local function box(range: number, width: number, height: number): Hitbox
	return { shape = "Box", range = range, width = width, height = height }
end

local Actions: { [string]: Action } = {
	---------------------------------------------------------------- Sword M1
	Sword_M1_1 = { displayName = "Slash", kind = "M1", cooldown = 0, windup = 0.15, recovery = 0.25, hitbox = box(6, 5, 5), damage = 8, animation = "Sword_M1_1" },
	Sword_M1_2 = { displayName = "Slash", kind = "M1", cooldown = 0, windup = 0.15, recovery = 0.25, hitbox = box(6, 5, 5), damage = 8, animation = "Sword_M1_2" },
	Sword_M1_3 = { displayName = "Slash", kind = "M1", cooldown = 0, windup = 0.15, recovery = 0.25, hitbox = box(6, 5, 5), damage = 8, animation = "Sword_M1_3" },
	Sword_M1_4 = {
		displayName = "Finisher",
		kind = "M1",
		cooldown = 0,
		windup = 0.2,
		recovery = 0.35,
		hitbox = box(6.5, 6, 5),
		damage = 11,
		effects = { { type = "Knockback", force = 35 } },
		animation = "Sword_M1_4",
	},

	---------------------------------------------------------------- Spear M1
	Spear_M1_1 = { displayName = "Jab", kind = "M1", cooldown = 0, windup = 0.18, recovery = 0.3, hitbox = box(9, 3, 4), damage = 9, animation = "Spear_M1_1" },
	Spear_M1_2 = { displayName = "Jab", kind = "M1", cooldown = 0, windup = 0.18, recovery = 0.3, hitbox = box(9, 3, 4), damage = 9, animation = "Spear_M1_2" },
	Spear_M1_3 = {
		displayName = "Drive",
		kind = "M1",
		cooldown = 0,
		windup = 0.25,
		recovery = 0.4,
		hitbox = box(10, 3, 4),
		damage = 12,
		effects = { { type = "Knockback", force = 40 } },
		animation = "Spear_M1_3",
	},

	------------------------------------------------------------ Ranged M1
	Bow_M1_1 = {
		displayName = "Shot",
		kind = "M1",
		cooldown = 0,
		windup = 0.45,
		recovery = 0.35,
		hitbox = { shape = "Ray", range = 180 },
		damage = 14,
		falloff = { startRange = 90, endRange = 180, minMultiplier = 0.6 },
		animation = "Bow_M1_1",
	},
	Rifle_M1_1 = {
		displayName = "Shot",
		kind = "M1",
		cooldown = 0,
		windup = 0.05,
		recovery = 0.2,
		hitbox = { shape = "Ray", range = 250 },
		damage = 7,
		falloff = { startRange = 80, endRange = 250, minMultiplier = 0.5 },
		animation = "Rifle_M1_1",
	},

	--------------------------------------------------------- Sword kit (Z/X/C)
	Sword_Lunge = { displayName = "Lunge", kind = "Kit", cooldown = 8, windup = 0.25, recovery = 0.4, hitbox = box(11, 4, 5), damage = 14, animation = "Sword_Lunge" },
	Sword_Sweep = {
		displayName = "Sweep",
		kind = "Kit",
		cooldown = 12,
		windup = 0.3,
		recovery = 0.45,
		hitbox = { shape = "Radius", radius = 8 },
		damage = 12,
		effects = { { type = "Knockback", force = 30 } },
		animation = "Sword_Sweep",
	},
	Sword_HeavySlash = {
		displayName = "Heavy Slash",
		kind = "Kit",
		cooldown = 16,
		windup = 0.5,
		recovery = 0.5,
		hitbox = box(7, 6, 6),
		damage = 20,
		effects = { { type = "Stun", duration = 1.0 } },
		animation = "Sword_HeavySlash",
	},

	--------------------------------------------------------- Spear kit (Z/X/C)
	Spear_Thrust = { displayName = "Thrust", kind = "Kit", cooldown = 8, windup = 0.3, recovery = 0.4, hitbox = box(14, 3, 4), damage = 15, animation = "Spear_Thrust" },
	Spear_Spin = {
		displayName = "Spin",
		kind = "Kit",
		cooldown = 12,
		windup = 0.3,
		recovery = 0.5,
		hitbox = { shape = "Radius", radius = 10 },
		damage = 11,
		effects = { { type = "Knockback", force = 35 } },
		animation = "Spear_Spin",
	},
	Spear_VaultStrike = {
		displayName = "Vault Strike",
		kind = "Kit",
		cooldown = 18,
		windup = 0.55,
		recovery = 0.5,
		hitbox = box(9, 6, 8),
		damage = 19,
		effects = { { type = "Stun", duration = 0.8 } },
		animation = "Spear_VaultStrike",
	},

	----------------------------------------------------------- Bow kit (Z/X/C)
	Bow_PowerShot = {
		displayName = "Power Shot",
		kind = "Kit",
		cooldown = 10,
		windup = 0.9,
		recovery = 0.4,
		hitbox = { shape = "Ray", range = 220 },
		damage = 24,
		animation = "Bow_PowerShot",
	},
	Bow_PinningShot = {
		displayName = "Pinning Shot",
		kind = "Kit",
		cooldown = 14,
		windup = 0.6,
		recovery = 0.4,
		hitbox = { shape = "Ray", range = 150 },
		damage = 10,
		effects = { { type = "Stun", duration = 1.5 } },
		animation = "Bow_PinningShot",
	},
	Bow_Volley = {
		displayName = "Volley",
		kind = "Kit",
		cooldown = 18,
		windup = 0.7,
		recovery = 0.5,
		hitbox = { shape = "Cone", range = 60, angle = 30 },
		maxTargets = 4,
		damage = 12,
		animation = "Bow_Volley",
	},

	--------------------------------------------------------- Rifle kit (Z/X/C)
	Rifle_Burst = {
		displayName = "Burst Fire",
		kind = "Kit",
		cooldown = 8,
		windup = 0.1,
		recovery = 0.3,
		hitbox = { shape = "Ray", range = 200 },
		damage = 6,
		hits = 3,
		hitInterval = 0.1,
		falloff = { startRange = 60, endRange = 200, minMultiplier = 0.5 },
		animation = "Rifle_Burst",
	},
	Rifle_StockBash = {
		displayName = "Stock Bash",
		kind = "Kit",
		cooldown = 10,
		windup = 0.2,
		recovery = 0.35,
		hitbox = box(5, 4, 5),
		damage = 9,
		effects = { { type = "Knockback", force = 45 }, { type = "Stun", duration = 0.5 } },
		animation = "Rifle_StockBash",
	},
	Rifle_AimedShot = {
		displayName = "Aimed Shot",
		kind = "Kit",
		cooldown = 16,
		windup = 1.0,
		recovery = 0.4,
		hitbox = { shape = "Ray", range = 400 },
		damage = 26,
		selfEffects = { { type = "SelfRoot", duration = 1.0 } },
		animation = "Rifle_AimedShot",
	},

	-------------------------------------------------------- Criticals (R)
	Crit_Sword_Execute = {
		displayName = "Execute",
		kind = "Critical",
		cooldown = 25,
		windup = 0.6,
		recovery = 0.6,
		hitbox = box(6, 4, 5),
		maxTargets = 1,
		damage = 30,
		animation = "Crit_Sword_Execute",
	},
	Crit_Sword_Cleave = {
		displayName = "Cleave",
		kind = "Critical",
		cooldown = 25,
		windup = 0.5,
		recovery = 0.6,
		hitbox = { shape = "Radius", radius = 9 },
		damage = 18,
		effects = { { type = "Knockback", force = 40 } },
		animation = "Crit_Sword_Cleave",
	},
	Crit_Spear_Impale = {
		displayName = "Impale",
		kind = "Critical",
		cooldown = 25,
		windup = 0.6,
		recovery = 0.6,
		hitbox = box(15, 3, 4),
		maxTargets = 1,
		damage = 28,
		effects = { { type = "Stun", duration = 1.0 } },
		animation = "Crit_Spear_Impale",
	},
	Crit_Spear_Sweep = {
		displayName = "Reaping Sweep",
		kind = "Critical",
		cooldown = 25,
		windup = 0.45,
		recovery = 0.6,
		hitbox = { shape = "Radius", radius = 11 },
		damage = 16,
		effects = { { type = "Knockback", force = 45 } },
		animation = "Crit_Spear_Sweep",
	},
	Crit_Bow_Heartseeker = {
		displayName = "Heartseeker",
		kind = "Critical",
		cooldown = 28,
		windup = 1.4,
		recovery = 0.5,
		hitbox = { shape = "Ray", range = 300 },
		damage = 34,
		selfEffects = { { type = "SelfRoot", duration = 1.4 } },
		animation = "Crit_Bow_Heartseeker",
	},
	Crit_Bow_Scatter = {
		displayName = "Scatter Shot",
		kind = "Critical",
		cooldown = 25,
		windup = 0.7,
		recovery = 0.5,
		hitbox = { shape = "Cone", range = 35, angle = 50 },
		maxTargets = 5,
		damage = 15,
		animation = "Crit_Bow_Scatter",
	},
	Crit_Rifle_Overcharge = {
		displayName = "Overcharge",
		kind = "Critical",
		cooldown = 25,
		windup = 0.8,
		recovery = 0.5,
		hitbox = { shape = "Ray", range = 250 },
		damage = 30,
		effects = { { type = "Knockback", force = 30 } },
		animation = "Crit_Rifle_Overcharge",
	},
	Crit_Rifle_Pierce = {
		displayName = "Piercing Round",
		kind = "Critical",
		cooldown = 25,
		windup = 1.1,
		recovery = 0.5,
		hitbox = { shape = "Ray", range = 400 },
		damage = 32,
		animation = "Crit_Rifle_Pierce",
	},

	----------------------------------------------------------- G abilities
	G_BattleCry = {
		displayName = "Battle Cry",
		kind = "G",
		cooldown = 60,
		windup = 0.4,
		recovery = 0.4,
		hitbox = { shape = "None" },
		selfEffects = { { type = "SelfBuff", damageMultiplier = 1.15, duration = 8 } },
		animation = "G_BattleCry",
	},
	G_Grab = {
		displayName = "Grab",
		kind = "G",
		cooldown = 30,
		windup = 0.25,
		recovery = 0.6,
		hitbox = box(4, 3, 5),
		maxTargets = 1,
		damage = 5,
		effects = { { type = "Stun", duration = 1.5 } },
		selfEffects = { { type = "SelfRoot", duration = 1.0 } },
		animation = "G_Grab",
	},
	G_SmokeGrenade = {
		displayName = "Smoke Grenade",
		kind = "G",
		cooldown = 45,
		windup = 0.4,
		recovery = 0.3,
		hitbox = { shape = "None" },
		selfEffects = { { type = "Smoke", radius = 14, duration = 10, distance = 20 } },
		animation = "G_SmokeGrenade",
	},
	G_DoubleBarrel = {
		displayName = "Double-Barrel Shotgun",
		kind = "G",
		cooldown = 90,
		windup = 0.6,
		recovery = 0.8,
		hitbox = { shape = "Cone", range = 25, angle = 25 },
		maxTargets = 1,
		damage = 95,
		falloff = { startRange = 8, endRange = 25, minMultiplier = 0.3 },
		effects = { { type = "Knockback", force = 60 } },
		animation = "G_DoubleBarrel",
	},
}

return table.freeze(Actions)
