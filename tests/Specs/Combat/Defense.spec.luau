--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Defense = require(ReplicatedStorage.Shared.Combat.Defense)

local S: Defense.Settings = {
	Block = {
		MaxCounts = 3,
		CountRegenTime = 4,
		BlockCooldown = 1,
		BreakLockout = 1.5,
		HitLockout = 0.7,
		PerfectWindowStart = 0,
		PerfectWindowEnd = 0.5,
		BlockBrokenDamageMultiplier = 1.5,
		PerfectBlockStun = 1.5,
		BlockBreakStun = 1.2,
	},
	Dodge = { MaxCharges = 2, ChargeCooldown = 4, IFrameDuration = 0.4 },
	HitStun = 0.7,
}

local function hit(damage: number, fromBehind: boolean?): Defense.HitInput
	return { damage = damage, fromBehind = fromBehind == true }
end

return function(t)
	t.test("an unblocked hit lands with hit stun", function()
		local d = Defense.new(S, 0)
		local out = Defense.resolveHit(S, d, 1, hit(10))
		t.expect(out.kind).toBe("Hit")
		t.expect(out.damage).toBe(10)
		t.expect(out.defenderStun).toBe(0.7)
	end)

	t.test("a block raised just before the hit is a perfect block that stuns the attacker", function()
		local d = Defense.new(S, 0)
		t.expect(Defense.startBlock(S, d, 10)).toBe(true)
		local out = Defense.resolveHit(S, d, 10.3, hit(10))
		t.expect(out.kind).toBe("PerfectBlock")
		t.expect(out.damage).toBe(0)
		t.expect(out.attackerStun).toBe(1.5)
		t.expect(d.blockCounts).toBe(3)
	end)

	t.test("a held block drains charges and breaks at zero", function()
		local d = Defense.new(S, 0)
		Defense.startBlock(S, d, 10)
		t.expect(Defense.resolveHit(S, d, 11, hit(10)).kind).toBe("Blocked")
		t.expect(Defense.resolveHit(S, d, 11.1, hit(10)).kind).toBe("Blocked")
		local out = Defense.resolveHit(S, d, 11.2, hit(10))
		t.expect(out.kind).toBe("BlockBroken")
		t.expect(out.damage).toBe(15)
		t.expect(out.defenderStun).toBe(1.2)
		t.expect(d.blocking).toBe(false)
		-- Locked out right after the break.
		t.expect((Defense.startBlock(S, d, 12))).toBe(false)
	end)

	t.test("hits from behind go through the block", function()
		local d = Defense.new(S, 0)
		Defense.startBlock(S, d, 10)
		local out = Defense.resolveHit(S, d, 11, hit(10, true))
		t.expect(out.kind).toBe("BlockBypassed")
		t.expect(out.damage).toBe(10)
		t.expect(d.blocking).toBe(false)
	end)

	t.test("a Critical (guard break) breaks a full held block in one hit", function()
		local d = Defense.new(S, 0)
		Defense.startBlock(S, d, 10)
		local out = Defense.resolveHit(S, d, 11, { damage = 10, fromBehind = false, guardBreak = true })
		t.expect(out.kind).toBe("BlockBroken")
		t.expect(out.damage).toBe(15)
		t.expect(d.blockCounts).toBe(0)
	end)

	t.test("a perfect block still stops a Critical", function()
		local d = Defense.new(S, 0)
		Defense.startBlock(S, d, 10)
		local out = Defense.resolveHit(S, d, 10.2, { damage = 10, fromBehind = false, guardBreak = true })
		t.expect(out.kind).toBe("PerfectBlock")
		t.expect(out.attackerStun).toBe(1.5)
	end)

	t.test("unblockable attacks ignore the block", function()
		local d = Defense.new(S, 0)
		Defense.startBlock(S, d, 10)
		local out = Defense.resolveHit(S, d, 11, { damage = 5, fromBehind = false, unblockable = true })
		t.expect(out.kind).toBe("Hit")
		t.expect(d.blocking).toBe(false)
	end)

	t.test("block charges regenerate while not blocking", function()
		local d = Defense.new(S, 0)
		Defense.startBlock(S, d, 10)
		Defense.resolveHit(S, d, 11, hit(10))
		Defense.resolveHit(S, d, 11.1, hit(10))
		t.expect(d.blockCounts).toBe(1)
		Defense.stopBlock(S, d, 12)
		Defense.regen(S, d, 16.5) -- 1 s cooldown, then less than one 4 s step
		t.expect(d.blockCounts).toBe(1)
		Defense.regen(S, d, 17.1)
		t.expect(d.blockCounts).toBe(2)
		Defense.regen(S, d, 30)
		t.expect(d.blockCounts).toBe(3)
	end)

	t.test("dodges use charges, give i-frames and recharge", function()
		local d = Defense.new(S, 0)
		t.expect(Defense.dodge(S, d, 10)).toBe(1)
		t.expect(Defense.resolveHit(S, d, 10.2, hit(10)).kind).toBe("Dodged")
		t.expect(Defense.resolveHit(S, d, 10.5, hit(10)).kind).toBe("Hit")
		t.expect(Defense.dodge(S, d, 10.6)).toBe(2)
		t.expect(Defense.dodge(S, d, 11)).toBeNil()
		t.expect(Defense.dodgeCharges(d, 14.1)).toBe(1)
	end)
end
