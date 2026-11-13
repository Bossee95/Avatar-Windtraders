local ServerScriptService = game:GetService("ServerScriptService")

local TerritoryEngine = require(ServerScriptService.Server.Services.Territory.TerritoryEngine)

local DEFS = {
	Ridge = { adjacent = { "Basin" }, startingController = "FactionA" },
	Basin = { adjacent = { "Ridge" } },
}

local function engine(overrides)
	local config = {
		BuildingFactions = { FactionA = true, FactionB = true },
		CaptureChangesTerritoryImmediately = true,
		NodeAccess = "ControllerOrContested",
		BuildAccess = "OwnedOrNeutral",
	}
	for k, v in pairs(overrides or {}) do
		config[k] = v
	end
	return TerritoryEngine.new({ territories = DEFS, config = config })
end

return function(t)
	t.test("starting controllers come from config", function()
		local e = engine()
		t.expect(e:Status("Ridge")).toBe("Held")
		t.expect(e:Status("Basin")).toBe("Neutral")
	end)

	t.test("capturing an anchor changes control immediately by default", function()
		local e = engine()
		t.expect(e:OnAnchorCaptured("Ridge", "FactionB", 10)).toBe("Changed")
		t.expect(e:Snapshot("Ridge").controller).toBe("FactionB")
		t.expect(e:Snapshot("Ridge").source).toBe("capture")
	end)

	t.test("with ratification on, capture only records a pending result", function()
		local e = engine({ CaptureChangesTerritoryImmediately = false })
		t.expect(e:OnAnchorCaptured("Ridge", "FactionB", 10)).toBe("Pending")
		t.expect(e:Snapshot("Ridge").controller).toBe("FactionA")
		t.expect(e:Snapshot("Ridge").pending.faction).toBe("FactionB")
		e:Rule("Ridge", "FactionB", nil, 20)
		t.expect(e:Snapshot("Ridge").pending).toBeNil()
	end)

	t.test("a Loreteam ruling can set control and lock it", function()
		local e = engine()
		t.expect((e:Rule("Basin", "FactionA", true, 5))).toBe(true)
		t.expect(e:CaptureAllowed("Basin")).toBe(false)
		t.expect(e:OnAnchorCaptured("Basin", "FactionB", 6)).toBe("Locked")
		t.expect(e:Snapshot("Basin").controller).toBe("FactionA")
		t.expect(select(2, e:Rule("Basin", "RogueA", nil, 7))).toBe("FactionNotAllowed")
		t.expect(select(2, e:Rule("Nowhere", nil, nil, 7))).toBe("UnknownTerritory")
	end)

	t.test("gathering and building access follow control", function()
		local e = engine()
		t.expect(e:CanGather("Ridge", "FactionA")).toBe(true)
		t.expect(e:CanGather("Ridge", "FactionB")).toBe(false)
		e:SetContested("Ridge", true)
		t.expect(e:Status("Ridge")).toBe("Contested")
		t.expect(e:CanGather("Ridge", "FactionB")).toBe(true)
		t.expect(e:CanGather("Basin", "FactionB")).toBe(true)
		t.expect(e:CanBuild("Ridge", "FactionB")).toBe(false)
		t.expect(e:CanBuild("Basin", "FactionB")).toBe(true)
		t.expect(e:CanBuild("Unmapped", "FactionB")).toBe(true)
	end)

	t.test("state survives save and load", function()
		local e = engine()
		e:Rule("Basin", "FactionB", true, 3)
		local loaded = engine()
		loaded:Load(e:Serialize())
		t.expect(loaded:Snapshot("Basin").controller).toBe("FactionB")
		t.expect(loaded:Snapshot("Basin").locked).toBe(true)
	end)
end
