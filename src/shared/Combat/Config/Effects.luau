--!strict
--[[
	Combat visual effects: which particle folder plays for which event.

	Each value names a Folder under ReplicatedStorage.VFX in the place (assets
	are made in Studio, not in this repo). Every ParticleEmitter in that folder
	is cloned onto the character's root and emitted once; an emitter's
	"BurstCount" attribute overrides the default count. A missing folder is
	skipped, so combat works before effects exist. The folder names match the
	original Studio combat's VFX folder.
]]

local Effects = {
	FolderName = "VFX",
	BurstCount = 25,
	Lifetime = 2, -- seconds before cloned emitters are cleaned up

	-- Unblocked hit on a target.
	Hit = "HitParticles",
	-- A Highlight under ReplicatedStorage.VFX.<HitFlash> flashed on the target.
	HitFlash = "FlashHit",
	HitFlashTime = 0.15,

	-- Body tints (Highlights), from Bossee's reference clip.
	BlockTint = Color3.fromRGB(60, 220, 210), -- steady while holding a block
	BlockTintTransparency = 0.65,
	PerfectBlockFlash = Color3.fromRGB(120, 255, 240), -- ~0.1 s on a perfect block
	PerfectBlockFlashTime = 0.12,
	GlowTransparency = 0.45, -- an action's `glow` colour (R's red), for the whole action

	-- CombatDefense kinds -> folder, played on the defender. Hits that land
	-- through a block (BlockBroken, BlockBypassed) also play Hit.
	Defense = {
		Blocked = "BlockHitParticles",
		PerfectBlock = "PerfectBlockParticles",
		BlockBroken = "BlockBrokenParticles",
		Dodged = "DodgedParticles",
		Dodge = "AirDashParticles",
	} :: { [string]: string },
}

return table.freeze(Effects)
