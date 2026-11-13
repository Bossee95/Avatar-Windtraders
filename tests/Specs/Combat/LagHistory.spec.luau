--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LagHistory = require(ReplicatedStorage.Shared.Combat.LagHistory)

return function(t)
	t.test("interpolates between samples", function()
		local h = LagHistory.new(4)
		LagHistory.push(h, 0, 0)
		LagHistory.push(h, 1, 10)
		t.expect(LagHistory.at(h, 0.5)).toBe(5)
		t.expect(LagHistory.at(h, 2)).toBe(10) -- newer than the newest: newest
	end)

	t.test("forgets samples older than its capacity", function()
		local h = LagHistory.new(3)
		for i = 0, 5 do
			LagHistory.push(h, i, i * 2)
		end
		t.expect(LagHistory.at(h, 3.5)).toBe(7)
		t.expect(LagHistory.at(h, 2)).toBeNil()
	end)

	t.test("is empty until something is pushed", function()
		t.expect(LagHistory.at(LagHistory.new(2), 0)).toBeNil()
	end)
end
