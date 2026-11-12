local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Table = require(ReplicatedStorage.Shared.Util.Table)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

return function(t)
	t.test("deepCopy makes independent nested copies", function()
		local original = { a = { b = 1 }, list = { 1, 2 } }
		local copy = Table.deepCopy(original)
		copy.a.b = 2
		t.expect(original.a.b).toBe(1)
		t.expect(Table.deepEqual(original.list, copy.list)).toBe(true)
	end)

	t.test("reconcile fills missing keys without overwriting", function()
		local target = { keep = 5, nested = { x = 1 } }
		Table.reconcile(target, { keep = 0, added = "y", nested = { x = 9, z = 2 }, list = {} })
		t.expect(target.keep).toBe(5)
		t.expect(target.added).toBe("y")
		t.expect(target.nested.x).toBe(1)
		t.expect(target.nested.z).toBe(2)
		t.expect(Table.deepEqual(target.list, {})).toBe(true)
	end)

	t.test("deepFreeze blocks writes", function()
		local frozen = Table.deepFreeze({ inner = { v = 1 } })
		t.expect(function()
			frozen.inner.v = 2
		end).toThrow()
	end)

	t.test("signal fires handlers and disconnects", function()
		local sig = Signal.new()
		local count = 0
		local conn = sig:Connect(function(n)
			count += n
		end)
		sig:Fire(2)
		conn:Disconnect()
		sig:Fire(5)
		t.expect(count).toBe(2)
	end)
end
