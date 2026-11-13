--!strict
--[[
	Defense: pure rules for blocking, perfect blocks and dodging (GDD §6.6).

	No Roblox APIs, so the rules can be tested anywhere. CombatService owns
	one state per player and feeds it the clock; this module only decides.

	Blocking
	  * A block has MaxCounts charges. Each blocked hit drains the attack's
	    blockDrain (default 1). At 0 the block breaks: the hit lands with
	    BlockBrokenDamageMultiplier and the defender is stunned.
	  * Criticals (guardBreak) break a held block outright.
	  * A hit within the perfect-block window after raising the block is a
	    perfect block: no damage, a charge back, and the attacker is stunned.
	  * Hits from behind ignore the block, cancel it and land normally.
	  * Charges come back one per CountRegenTime while not blocking.
	  * After a block ends or breaks it can't be raised again for BlockCooldown
	    (or BreakLockout after a break). Taking a hit locks blocking for HitLockout.

	Dodging
	  * Dodge has MaxCharges charges; each one recharges ChargeCooldown after
	    use. A dodge gives IFrameDuration of invulnerability: hits in that
	    window are dodged.
]]

export type Settings = {
	Block: {
		MaxCounts: number,
		CountRegenTime: number,
		BlockCooldown: number,
		BreakLockout: number,
		HitLockout: number,
		PerfectWindowStart: number,
		PerfectWindowEnd: number,
		BlockBrokenDamageMultiplier: number,
		PerfectBlockStun: number,
		BlockBreakStun: number,
	},
	Dodge: {
		MaxCharges: number,
		ChargeCooldown: number,
		IFrameDuration: number,
	},
	HitStun: number,
}

export type State = {
	blockCounts: number,
	blocking: boolean,
	blockStartedAt: number,
	blockLockedUntil: number,
	lastRegenAt: number,
	dodgeReadyAt: { number },
	iframesUntil: number,
}

export type HitInput = {
	damage: number,
	blockDrain: number?,
	fromBehind: boolean,
	unblockable: boolean?,
	-- Criticals (R): a held block breaks outright; a perfect block still stops it.
	guardBreak: boolean?,
}

export type HitOutcome = {
	kind: "Hit" | "Blocked" | "PerfectBlock" | "BlockBroken" | "BlockBypassed" | "Dodged",
	damage: number,
	defenderStun: number,
	attackerStun: number,
}

local Defense = {}

function Defense.new(settings: Settings, now: number): State
	local charges = {}
	for i = 1, settings.Dodge.MaxCharges do
		charges[i] = 0
	end
	return {
		blockCounts = settings.Block.MaxCounts,
		blocking = false,
		blockStartedAt = 0,
		blockLockedUntil = 0,
		lastRegenAt = now,
		dodgeReadyAt = charges,
		iframesUntil = 0,
	}
end

-- Brings block charges up to date. Call before reading blockCounts.
function Defense.regen(settings: Settings, state: State, now: number)
	local max = settings.Block.MaxCounts
	if state.blocking or state.blockCounts >= max then
		state.lastRegenAt = now
		return
	end
	-- Regen starts counting once any lockout is over.
	local from = math.max(state.lastRegenAt, state.blockLockedUntil)
	if now < from then
		return
	end
	local step = settings.Block.CountRegenTime
	if step <= 0 then
		state.blockCounts = max
		state.lastRegenAt = now
		return
	end
	local gained = math.floor((now - from) / step)
	if gained > 0 then
		state.blockCounts = math.min(max, state.blockCounts + gained)
		state.lastRegenAt = from + gained * step
	end
end

function Defense.startBlock(settings: Settings, state: State, now: number): (boolean, string?)
	Defense.regen(settings, state, now)
	if state.blocking then
		return true, nil
	end
	if now < state.blockLockedUntil then
		return false, "BlockLocked"
	end
	if state.blockCounts <= 0 then
		return false, "BlockBroken"
	end
	state.blocking = true
	state.blockStartedAt = now
	return true, nil
end

function Defense.stopBlock(settings: Settings, state: State, now: number)
	if not state.blocking then
		return
	end
	state.blocking = false
	state.lastRegenAt = now
	state.blockLockedUntil = math.max(state.blockLockedUntil, now + settings.Block.BlockCooldown)
end

-- Returns the charge index used, or nil if every charge is recharging.
function Defense.dodge(settings: Settings, state: State, now: number): number?
	for i, readyAt in state.dodgeReadyAt do
		if now >= readyAt then
			state.dodgeReadyAt[i] = now + settings.Dodge.ChargeCooldown
			state.iframesUntil = now + settings.Dodge.IFrameDuration
			return i
		end
	end
	return nil
end

function Defense.dodgeCharges(state: State, now: number): number
	local n = 0
	for _, readyAt in state.dodgeReadyAt do
		if now >= readyAt then
			n += 1
		end
	end
	return n
end

function Defense.resolveHit(settings: Settings, state: State, now: number, hit: HitInput): HitOutcome
	local block = settings.Block
	if now < state.iframesUntil then
		return { kind = "Dodged", damage = 0, defenderStun = 0, attackerStun = 0 }
	end
	Defense.regen(settings, state, now)

	if state.blocking and not hit.unblockable then
		if hit.fromBehind then
			state.blocking = false
			state.lastRegenAt = now
			state.blockLockedUntil = math.max(state.blockLockedUntil, now + block.HitLockout)
			return {
				kind = "BlockBypassed",
				damage = hit.damage,
				defenderStun = settings.HitStun,
				attackerStun = 0,
			}
		end
		local held = now - state.blockStartedAt
		if held >= block.PerfectWindowStart and held <= block.PerfectWindowEnd then
			state.blockCounts = math.min(block.MaxCounts, state.blockCounts + 1)
			return {
				kind = "PerfectBlock",
				damage = 0,
				defenderStun = 0,
				attackerStun = block.PerfectBlockStun,
			}
		end
		state.blockCounts -= if hit.guardBreak then state.blockCounts else (hit.blockDrain or 1)
		if state.blockCounts <= 0 then
			state.blockCounts = 0
			state.blocking = false
			state.lastRegenAt = now
			state.blockLockedUntil = math.max(state.blockLockedUntil, now + block.BreakLockout)
			return {
				kind = "BlockBroken",
				damage = hit.damage * block.BlockBrokenDamageMultiplier,
				defenderStun = block.BlockBreakStun,
				attackerStun = 0,
			}
		end
		return { kind = "Blocked", damage = 0, defenderStun = 0, attackerStun = 0 }
	end

	if state.blocking then
		-- Unblockable attacks still drop the guard.
		state.blocking = false
		state.lastRegenAt = now
	end
	state.blockLockedUntil = math.max(state.blockLockedUntil, now + block.HitLockout)
	return { kind = "Hit", damage = hit.damage, defenderStun = settings.HitStun, attackerStun = 0 }
end

return Defense
