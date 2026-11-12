local ServerScriptService = game:GetService("ServerScriptService")

local NodeEngine = require(ServerScriptService.Server.Services.Production.NodeEngine)

local TYPES = {
	Pile = {
		tier = "Common",
		yields = { { item = "Material.Common", min = 2, max = 4 } },
		gatherTime = 1,
		capacity = 3,
		regen = { mode = "Timed", every = 10 },
	},
	Vein = {
		tier = "Rare",
		yields = { { item = "Material.Rare", min = 1, max = 1 }, { item = "Material.Rare", min = 1, max = 1, chance = 0.5 } },
		gatherTime = 1,
		capacity = 2,
		regen = { mode = "PerEvent" },
		factions = { "FactionB" },
	},
	Tooled = {
		tier = "Industrial",
		yields = { { item = "Material.Industrial", min = 1, max = 1 } },
		gatherTime = 1,
		capacity = 1,
		toolTag = "Tool.Cutter",
	},
}

local function engine(rollValue)
	local e = NodeEngine.new({
		nodeTypes = TYPES,
		random = function(min)
			return min
		end,
		roll = function()
			return rollValue or 0
		end,
	})
	e:AddNode("p1", "Pile")
	e:AddNode("v1", "Vein")
	e:AddNode("t1", "Tooled")
	return e
end

local ctxA = { faction = "FactionA", hasItem = function() return false end }
local ctxB = { faction = "FactionB", hasItem = function() return false end }

return function(t)
	t.test("nodes deplete after capacity gathers", function()
		local e = engine()
		for _ = 1, 3 do
			t.expect((e:CanGather("p1", ctxA))).toBe(true)
			t.expect(e:Harvest("p1")).toEqual({ ["Material.Common"] = 2 })
		end
		local ok, err = e:CanGather("p1", ctxA)
		t.expect(ok).toBe(false)
		t.expect(err).toBe("NodeDepleted")
	end)

	t.test("timed regen refills one unit per interval during a PD", function()
		local e = engine()
		e:Harvest("p1")
		e:Harvest("p1")
		t.expect(#e:Tick(9)).toBe(0)
		t.expect(#e:Tick(1)).toBe(1)
		t.expect(e:Snapshot("p1").remaining).toBe(2)
		e:Tick(100)
		t.expect(e:Snapshot("p1").remaining).toBe(3)
	end)

	t.test("PerEvent nodes refill only when an event starts", function()
		local e = engine()
		e:Harvest("v1")
		e:Tick(1000)
		t.expect(e:Snapshot("v1").remaining).toBe(1)
		t.expect(e:RefillForEvent()).toEqual({ "v1" })
		t.expect(e:Snapshot("v1").remaining).toBe(2)
	end)

	t.test("faction, tool and territory rules are enforced", function()
		local e = engine()
		t.expect(select(2, e:CanGather("v1", ctxA))).toBe("FactionNotAllowed")
		t.expect((e:CanGather("v1", ctxB))).toBe(true)
		t.expect(select(2, e:CanGather("t1", ctxA))).toBe("MissingTool")
		local withTool = { faction = "FactionA", hasItem = function(id) return id == "Tool.Cutter" end }
		t.expect((e:CanGather("t1", withTool))).toBe(true)
		local denied = { faction = "FactionA", hasItem = function() return true end, territoryOk = false }
		t.expect(select(2, e:CanGather("p1", denied))).toBe("TerritoryDenied")
	end)

	t.test("chance yields roll independently", function()
		t.expect(engine(0.9):Harvest("v1")).toEqual({ ["Material.Rare"] = 1 })
		t.expect(engine(0.1):Harvest("v1")).toEqual({ ["Material.Rare"] = 2 })
	end)

	t.test("refund gives back a spent unit", function()
		local e = engine()
		e:Harvest("p1")
		e:Refund("p1")
		t.expect(e:Snapshot("p1").remaining).toBe(3)
		e:Refund("p1")
		t.expect(e:Snapshot("p1").remaining).toBe(3)
	end)

	t.test("staff overrides disable, resize and set stock", function()
		local e = engine()
		t.expect((e:SetEnabled("p1", false))).toBe(true)
		t.expect(select(2, e:CanGather("p1", ctxA))).toBe("NodeDisabled")
		e:SetEnabled("p1", true)
		e:SetCapacity("p1", 1)
		t.expect(e:Snapshot("p1").remaining).toBe(1)
		t.expect(select(2, e:SetRemaining("p1", 5))).toBe("InvalidAmount")
		t.expect(select(2, e:SetCapacity("missing", 1))).toBe("UnknownNode")
	end)

	t.test("saved state survives a reload in either order", function()
		local e = engine()
		e:Harvest("p1")
		e:SetEnabled("v1", false)
		local saved = e:Serialize()

		local before = NodeEngine.new({ nodeTypes = TYPES })
		before:Load(saved)
		before:AddNode("p1", "Pile")
		before:AddNode("v1", "Vein")
		t.expect(before:Snapshot("p1").remaining).toBe(2)
		t.expect(before:Snapshot("v1").enabled).toBe(false)

		local after = NodeEngine.new({ nodeTypes = TYPES })
		after:AddNode("p1", "Pile")
		after:Load(saved)
		t.expect(after:Snapshot("p1").remaining).toBe(2)
	end)

	t.test("bad node types are rejected at load", function()
		t.expect(function()
			NodeEngine.new({ nodeTypes = { Bad = { capacity = 0, gatherTime = 1, yields = { { item = "x", min = 1, max = 1 } } } } })
		end).toThrow()
		t.expect(function()
			NodeEngine.new({ nodeTypes = { Bad = { capacity = 1, gatherTime = 1, yields = {}, regen = { mode = "None" } } } })
		end).toThrow()
		local e = NodeEngine.new({ nodeTypes = TYPES })
		t.expect(select(2, e:AddNode("x", "Missing"))).toBe("UnknownNodeType")
	end)
end
