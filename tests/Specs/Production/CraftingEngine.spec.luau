local ServerScriptService = game:GetService("ServerScriptService")

local CraftingEngine = require(ServerScriptService.Server.Services.Production.CraftingEngine)

local STATIONS = { Forge = { displayName = "Forge" }, Bench = { displayName = "Bench" } }

local RECIPES = {
	Sword = {
		displayName = "Sword",
		inputs = { ["Material.Common"] = 3, ["Material.Industrial"] = 1 },
		outputs = { { item = "Weapon.Sword", qty = 1 } },
		station = "Forge",
		craftTime = 1,
	},
	Elite = {
		displayName = "Elite",
		inputs = { ["Material.Rare"] = 1 },
		outputs = { { item = "Weapon.Elite", qty = 1 } },
		station = "Forge",
		craftTime = 1,
		factions = { "FactionA" },
		minRank = 3,
		permission = "craft_weapons",
	},
}

-- In-memory inventory adapter for Apply.
local function bag(initial, failGrant)
	local items = {}
	for k, v in pairs(initial) do
		items[k] = v
	end
	local adapter = {
		count = function(id)
			return items[id] or 0
		end,
		consume = function(id, qty)
			if (items[id] or 0) < qty then
				return false, "InsufficientQuantity"
			end
			items[id] = items[id] - qty
			return true
		end,
		grant = function(id, qty)
			if failGrant == id then
				return false, "Boom"
			end
			items[id] = (items[id] or 0) + qty
			return true
		end,
	}
	adapter.ungrant = function(id, qty)
		items[id] = items[id] - qty
	end
	adapter.unconsume = function(id, qty)
		items[id] = (items[id] or 0) + qty
	end
	return adapter, items
end

local function ctx(overrides)
	local items = overrides.items or { ["Material.Common"] = 10, ["Material.Industrial"] = 10, ["Material.Rare"] = 10 }
	return {
		faction = overrides.faction or "FactionA",
		rank = overrides.rank or 1,
		hasPermission = function(flag)
			return overrides.perms ~= nil and overrides.perms[flag] == true
		end,
		countOf = function(id)
			return items[id] or 0
		end,
		station = overrides.station or { type = "Forge", operational = true },
	}
end

return function(t)
	local e = CraftingEngine.new({ recipes = RECIPES, stations = STATIONS })

	t.test("a craft needs the right station, working", function()
		t.expect((e:Check("Sword", ctx({})))).toBe(true)
		t.expect(select(2, e:Check("Sword", ctx({ station = { type = "Bench", operational = true } })))).toBe("WrongStation")
		t.expect(select(2, e:Check("Sword", ctx({ station = { type = "Forge", operational = false } })))).toBe("StationUnavailable")
		t.expect(select(2, e:Check("Sword", ctx({ station = { type = "Forge", operational = true, faction = "FactionB" } })))).toBe("StationNotYours")
	end)

	t.test("a craft needs every input", function()
		local c = ctx({ items = { ["Material.Common"] = 3 } })
		t.expect(select(2, e:Check("Sword", c))).toBe("MissingMaterials")
	end)

	t.test("faction, rank and permission requirements apply", function()
		t.expect(select(2, e:Check("Elite", ctx({ faction = "FactionB", rank = 5, perms = { craft_weapons = true } })))).toBe("FactionNotAllowed")
		t.expect(select(2, e:Check("Elite", ctx({ rank = 2, perms = { craft_weapons = true } })))).toBe("RankTooLow")
		t.expect(select(2, e:Check("Elite", ctx({ rank = 3 })))).toBe("MissingPermission")
		t.expect((e:Check("Elite", ctx({ rank = 3, perms = { craft_weapons = true } })))).toBe(true)
	end)

	t.test("staff locks block a recipe globally or for one faction", function()
		local l = CraftingEngine.new({ recipes = RECIPES, stations = STATIONS })
		l:SetLocked("Sword", "FactionA", true)
		t.expect(select(2, l:Check("Sword", ctx({})))).toBe("RecipeLocked")
		t.expect((l:Check("Sword", ctx({ faction = "FactionB" })))).toBe(true)
		l:SetLocked("Sword", "FactionA", false)
		l:SetLocked("Sword", nil, true)
		t.expect(select(2, l:Check("Sword", ctx({ faction = "FactionB" })))).toBe("RecipeLocked")
		local restored = CraftingEngine.new({ recipes = RECIPES, stations = STATIONS })
		restored:LoadLocks(l:SerializeLocks())
		t.expect(restored:IsLocked("Sword", "FactionB")).toBe(true)
		t.expect(select(2, l:SetLocked("Missing", nil, true))).toBe("UnknownRecipe")
	end)

	t.test("apply swaps inputs for outputs", function()
		local inv, items = bag({ ["Material.Common"] = 5, ["Material.Industrial"] = 1 })
		t.expect((CraftingEngine.Apply(e:Plan("Sword"), inv))).toBe(true)
		t.expect(items["Material.Common"]).toBe(2)
		t.expect(items["Material.Industrial"]).toBe(0)
		t.expect(items["Weapon.Sword"]).toBe(1)
	end)

	t.test("apply is all or nothing", function()
		local inv, items = bag({ ["Material.Common"] = 5, ["Material.Industrial"] = 1 }, "Weapon.Sword")
		local ok, err = CraftingEngine.Apply(e:Plan("Sword"), inv)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("Boom")
		t.expect(items["Material.Common"]).toBe(5)
		t.expect(items["Material.Industrial"]).toBe(1)
		t.expect(items["Weapon.Sword"]).toBeNil()

		local short, shortItems = bag({ ["Material.Common"] = 5 })
		t.expect(select(2, CraftingEngine.Apply(e:Plan("Sword"), short))).toBe("MissingMaterials")
		t.expect(shortItems["Material.Common"]).toBe(5)
	end)

	t.test("crafting outputs are items only, never kits", function()
		local plan = e:Plan("Elite")
		for _, g in ipairs(plan.grant) do
			t.expect(type(g.item)).toBe("string")
			t.expect(g.kit).toBeNil()
		end
		t.expect(CraftingEngine.GrantKit).toBeNil()
	end)

	t.test("bad recipes are rejected at load", function()
		t.expect(function()
			CraftingEngine.new({ recipes = { Bad = { displayName = "x", inputs = {}, outputs = { { item = "a", qty = 1 } }, station = "Forge", craftTime = 1 } }, stations = STATIONS })
		end).toThrow()
		t.expect(function()
			CraftingEngine.new({ recipes = { Bad = { displayName = "x", inputs = { a = 1 }, outputs = { { item = "a", qty = 1 } }, station = "Nope", craftTime = 1 } }, stations = STATIONS })
		end).toThrow()
		t.expect(function()
			CraftingEngine.new({
				recipes = RECIPES,
				stations = STATIONS,
				itemExists = function(id)
					return id ~= "Weapon.Elite"
				end,
			})
		end).toThrow()
	end)

	t.test("ListFor shows every recipe at a station with its blocker", function()
		local list = e:ListFor("Forge", ctx({}))
		t.expect(#list).toBe(2)
		t.expect(list[1].id).toBe("Elite")
		t.expect(list[1].reason).toBe("RankTooLow")
		t.expect(list[2].ok).toBe(true)
	end)
end
