local ServerScriptService = game:GetService("ServerScriptService")

local Fixtures = require(ServerScriptService.Tests.Economy.EconomyFixtures)

-- Kills player 1 (who carries a sword, 20 common material and an untradeable heirloom).
local function killed(w)
	local dead = w.player(1)
	w.give(dead, "Weapon.Sword")
	w.give(dead, "Material.Common", 20)
	w.give(dead, "Special.Heirloom")
	local result = w.satchels:CreateFromDeath({
		userId = dead.UserId,
		characterId = dead.characterId,
		pdEventId = w.pdEventId,
		faction = dead.faction,
		location = 0,
	})
	return dead, result
end

return function(t)
	t.test("tradeable items go into the satchel and untradeable ones are destroyed", function()
		local w = Fixtures.world()
		local dead, result = killed(w)
		t.expect(result.satchel ~= nil).toBe(true)
		local contents = w.satchels:Contents(result.satchel.id)
		t.expect(#contents).toBe(2)
		t.expect(#result.destroyed).toBe(1)
		t.expect(result.destroyed[1].itemId).toBe("Special.Heirloom")
		t.expect(#w.inventory:GetContainer(w.charKey(dead))).toBe(0)
	end)

	t.test("no satchel is created when nothing tradeable was carried", function()
		local w = Fixtures.world()
		local dead = w.player(1)
		w.give(dead, "Special.Heirloom")
		local result = w.satchels:CreateFromDeath({ userId = 1, characterId = dead.characterId, pdEventId = "pd-1" })
		t.expect(result.satchel).toBeNil()
		t.expect(#w.satchels:List()).toBe(0)
	end)

	t.test("other players can loot during the same PD", function()
		local w = Fixtures.world()
		local _, result = killed(w)
		local looter = w.player(2)
		local ok, taken = w.satchels:Loot(looter, result.satchel.id, nil)
		t.expect(ok).toBe(true)
		t.expect(#taken).toBe(2)
		t.expect(w.inventory:CountOf(w.charKey(looter), "Material.Common")).toBe(20)
		t.expect(w.satchels:Get(result.satchel.id)).toBeNil()
		t.expect(#w.log:Query({ kind = "SatchelLoot", playerUserId = 1 })).toBe(1)
	end)

	t.test("two players claiming the same item: the first wins, the second fails", function()
		local w = Fixtures.world()
		local _, result = killed(w)
		local sword
		for _, item in ipairs(w.satchels:Contents(result.satchel.id)) do
			if item.itemId == "Weapon.Sword" then
				sword = item
			end
		end
		local p2, p3 = w.player(2), w.player(3)
		t.expect((w.satchels:Loot(p2, result.satchel.id, { { uid = sword.uid } }))).toBe(true)
		local ok, reason = w.satchels:Loot(p3, result.satchel.id, { { uid = sword.uid } })
		t.expect(ok).toBe(false)
		t.expect(reason).toBe("ItemGone")
		t.expect(w.inventory:CountOf(w.charKey(p2), "Weapon.Sword")).toBe(1)
		t.expect(w.inventory:CountOf(w.charKey(p3), "Weapon.Sword")).toBe(0)
	end)

	t.test("satchels cannot be looted outside their PD", function()
		local w = Fixtures.world()
		local _, result = killed(w)
		w.pdEventId = "pd-2"
		local ok, reason = w.satchels:Loot(w.player(2), result.satchel.id, nil)
		t.expect(ok).toBe(false)
		t.expect(reason).toBe("PDNotActive")
		w.pdEventId = "pd-1"
		w.pdActive = false
		ok, reason = w.satchels:Loot(w.player(2), result.satchel.id, nil)
		t.expect(reason).toBe("PDNotActive")
	end)

	t.test("ending the PD removes its satchels and their contents", function()
		local w = Fixtures.world()
		local _, result = killed(w)
		local key = result.satchel.container
		t.expect(w.satchels:ClearEvent("pd-1")).toBe(1)
		t.expect(w.satchels:Get(result.satchel.id)).toBeNil()
		t.expect(#w.inventory:GetContainer(key)).toBe(0)
		local cleared = w.log:Query({ kind = "SatchelCleared" })
		t.expect(#cleared).toBe(1)
		t.expect(#cleared[1].items).toBe(2)
	end)

	t.test("ClearStale removes satchels from other events only", function()
		local w = Fixtures.world()
		killed(w)
		t.expect(w.satchels:ClearStale("pd-1")).toBe(0)
		t.expect(w.satchels:ClearStale("pd-2")).toBe(1)
	end)

	t.test("the owner cannot loot their own satchel by default", function()
		local w = Fixtures.world()
		local dead, result = killed(w)
		dead.characterId = "1-2"
		local ok, reason = w.satchels:Loot(dead, result.satchel.id, nil)
		t.expect(ok).toBe(false)
		t.expect(reason).toBe("OwnSatchel")
	end)

	t.test("loot policy SameFaction blocks other factions", function()
		local w = Fixtures.world({ SatchelLootableBy = "SameFaction" })
		local _, result = killed(w)
		local ok, reason = w.satchels:Loot(w.player(2, "FactionB"), result.satchel.id, nil)
		t.expect(ok).toBe(false)
		t.expect(reason).toBe("WrongFaction")
		t.expect((w.satchels:Loot(w.player(3, "FactionA"), result.satchel.id, nil))).toBe(true)
	end)

	t.test("with concurrent looting off, the first opener holds the satchel", function()
		local w = Fixtures.world({ SatchelConcurrentLooting = false })
		local _, result = killed(w)
		local p2, p3 = w.player(2), w.player(3)
		t.expect((w.satchels:Open(p2, result.satchel.id))).toBe(true)
		local ok, reason = w.satchels:Open(p3, result.satchel.id)
		t.expect(ok).toBe(false)
		t.expect(reason).toBe("InUse")
		w.satchels:Close(p2, result.satchel.id)
		t.expect((w.satchels:Open(p3, result.satchel.id))).toBe(true)
	end)

	t.test("looters must be in range", function()
		local w = Fixtures.world()
		local _, result = killed(w)
		local p = w.player(2)
		p.position = w.config.SatchelLootRange + 1
		local ok, reason = w.satchels:Loot(p, result.satchel.id, nil)
		t.expect(ok).toBe(false)
		t.expect(reason).toBe("TooFar")
	end)

	t.test("stored items stay out of the satchel unless the flag is on", function()
		local w = Fixtures.world()
		local dead = w.player(1)
		local storage = w.inventory.Container.Storage(dead.characterId)
		w.inventory:Grant(storage, "Material.Rare", 5)
		local result = w.satchels:CreateFromDeath({ userId = 1, characterId = dead.characterId, pdEventId = "pd-1" })
		t.expect(result.satchel).toBeNil()
		t.expect(w.inventory:CountOf(storage, "Material.Rare")).toBe(5)

		local w2 = Fixtures.world({ StorageItemsDropOnDeath = true })
		local dead2 = w2.player(1)
		local storage2 = w2.inventory.Container.Storage(dead2.characterId)
		w2.inventory:Grant(storage2, "Material.Rare", 5)
		local result2 = w2.satchels:CreateFromDeath({ userId = 1, characterId = dead2.characterId, pdEventId = "pd-1" })
		t.expect(#w2.satchels:Contents(result2.satchel.id)).toBe(1)
	end)

	t.test("UndoDeath puts everything back when the death is rolled back", function()
		local w = Fixtures.world()
		local dead = w.player(1)
		w.give(dead, "Weapon.Sword")
		w.give(dead, "Special.Heirloom")
		local death = { userId = 1, characterId = dead.characterId, pdEventId = "pd-1" }
		local result = w.satchels:CreateFromDeath(death)
		w.satchels:UndoDeath(death, result)
		t.expect(#w.satchels:List()).toBe(0)
		t.expect(w.inventory:CountOf(w.charKey(dead), "Weapon.Sword")).toBe(1)
		t.expect(w.inventory:CountOf(w.charKey(dead), "Special.Heirloom")).toBe(1)
	end)
end
