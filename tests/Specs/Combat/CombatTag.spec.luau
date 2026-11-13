--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local Combat = ServerScriptService.Server.Services.Combat
local CombatTag = require(Combat.CombatTag)
local Cooldowns = require(Combat.Cooldowns)

return function(t)
	t.test("combat tag lasts its duration and refreshes", function()
		local now = 0
		local tags = CombatTag.new(20, function()
			return now
		end)
		t.expect(tags:tag("a")).toBe(true)
		now = 10
		t.expect(tags:tag("a")).toBe(false) -- refresh, not a new tag
		now = 25
		t.expect(tags:isTagged("a")).toBe(true)
		now = 30
		t.expect(tags:isTagged("a")).toBe(false)
		t.expect(#tags:collectExpired()).toBe(1)
		t.expect(#tags:collectExpired()).toBe(0)
	end)

	t.test("clearing a tag reports whether it was active", function()
		local tags = CombatTag.new(5, function()
			return 0
		end)
		t.expect(tags:clear("a")).toBe(false)
		tags:tag("a")
		t.expect(tags:clear("a")).toBe(true)
		t.expect(tags:isTagged("a")).toBe(false)
	end)

	t.test("cooldowns block until they expire", function()
		local now = 0
		local cd = Cooldowns.new(function()
			return now
		end)
		t.expect((cd:isReady("p", "Sword_Lunge"))).toBe(true)
		cd:start("p", "Sword_Lunge", 8)
		local ready, left = cd:isReady("p", "Sword_Lunge")
		t.expect(ready).toBe(false)
		t.expect(left).toBe(8)
		t.expect((cd:isReady("p", "Sword_Sweep"))).toBe(true)
		t.expect((cd:isReady("q", "Sword_Lunge"))).toBe(true)
		now = 8
		t.expect((cd:isReady("p", "Sword_Lunge"))).toBe(true)
	end)

	t.test("cooldown snapshot lists only active cooldowns", function()
		local now = 0
		local cd = Cooldowns.new(function()
			return now
		end)
		cd:start("p", "A", 5)
		cd:start("p", "B", 1)
		now = 2
		local snap = cd:snapshot("p")
		t.expect(snap.A).toBe(3)
		t.expect(snap.B).toBeNil()
		cd:clear("p")
		t.expect(next(cd:snapshot("p"))).toBeNil()
	end)
end
