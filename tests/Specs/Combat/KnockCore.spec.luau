--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KnockCore = require(ReplicatedStorage.Shared.Combat.KnockCore)

local S: KnockCore.Settings = {
	HealthLimit = 6,
	Duration = 7,
	ExtendOnDamage = 3,
	GripDuration = 3,
	DropImmunity = 1,
	SearchRadius = 7,
}

return function(t)
	t.test("a downed character gets up after the duration", function()
		local s = KnockCore.knock(S, 0)
		t.expect(KnockCore.shouldRecover(s, 6.9)).toBe(false)
		t.expect(KnockCore.shouldRecover(s, 7)).toBe(true)
	end)

	t.test("damage while down extends the timer up to the full duration", function()
		local s = KnockCore.knock(S, 0)
		KnockCore.onDamaged(S, s, 5) -- 2 s left + 3
		t.expect(KnockCore.timeLeft(s, 5)).toBe(5)
		KnockCore.onDamaged(S, s, 5) -- capped at 7
		t.expect(KnockCore.timeLeft(s, 5)).toBe(7)
	end)

	t.test("carrying pauses the timer and dropping resumes it with immunity", function()
		local s = KnockCore.knock(S, 0)
		t.expect((KnockCore.startCarry(s, 2, 1))).toBe(true)
		t.expect(KnockCore.shouldRecover(s, 100)).toBe(false)
		KnockCore.stopCarry(S, s, 100)
		t.expect(KnockCore.timeLeft(s, 100)).toBe(5)
		t.expect((KnockCore.startCarry(s, 100.5, 2))).toBe(false) -- drop immunity
		t.expect((KnockCore.startCarry(s, 101.5, 2))).toBe(true)
	end)

	t.test("an execution finishes after the grip duration unless cancelled", function()
		local s = KnockCore.knock(S, 0)
		t.expect((KnockCore.startGrip(S, s, 1, 9))).toBe(true)
		t.expect(KnockCore.gripFinished(s, 3.9)).toBe(false)
		t.expect(KnockCore.gripFinished(s, 4)).toBe(true)

		local s2 = KnockCore.knock(S, 0)
		KnockCore.startGrip(S, s2, 1, 9)
		KnockCore.cancelGrip(S, s2, 2)
		t.expect(s2.mode).toBe("Down")
		t.expect(KnockCore.gripFinished(s2, 10)).toBe(false)
		t.expect(KnockCore.timeLeft(s2, 2)).toBe(6)
	end)

	t.test("only one person can hold a downed character", function()
		local s = KnockCore.knock(S, 0)
		KnockCore.startCarry(s, 1, 1)
		t.expect((KnockCore.startGrip(S, s, 1.5, 2))).toBe(false)
		t.expect((KnockCore.startCarry(s, 1.5, 2))).toBe(false)
	end)

	t.test("picks the nearest downed character in range", function()
		local down = KnockCore.knock(S, 0)
		local far = KnockCore.knock(S, 0)
		local index = KnockCore.pickTarget(S, 1, {
			{ distance = 3, state = nil },
			{ distance = 9, state = far },
			{ distance = 5, state = down },
		})
		t.expect(index).toBe(3)
		t.expect(KnockCore.pickTarget(S, 1, { { distance = 8, state = down } })).toBeNil()
	end)
end
