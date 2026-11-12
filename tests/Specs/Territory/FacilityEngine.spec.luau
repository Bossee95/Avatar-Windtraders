local ServerScriptService = game:GetService("ServerScriptService")

local FacilityEngine = require(ServerScriptService.Server.Services.Territory.FacilityEngine)

local CONFIG = {
	BuildingFactions = { FactionA = true, FactionB = true },
	MaxFacilitiesPerFaction = 2,
	ConstructionHealthShare = 0.1,
	DamagedThreshold = 0.5,
	CaptureDecayRate = 0.5,
}

local TYPES = {
	Base = {
		displayName = "Base",
		factions = { "FactionA" },
		cost = { ["Material.Common"] = 10 },
		buildPoints = 20,
		maxHealth = 1000,
		provides = { "station:Forge", "storage" },
		capturable = true,
		captureRadius = 10,
		captureTime = 10,
	},
	Shrine = {
		displayName = "Shrine",
		factions = { "FactionB" },
		cost = { ["Material.Natural"] = 5 },
		buildPoints = 10,
		maxHealth = 500,
		provides = {},
		capturable = false,
	},
}

local A = { faction = "FactionA", canBuild = true }

local function built()
	local e = FacilityEngine.new({ types = TYPES, config = CONFIG })
	local _, id = e:Place("Base", "z1", "NorthRidge", A, 0)
	e:Contribute(id, "FactionA", "Material.Common", 10)
	e:Work(id, "FactionA", 20)
	return e, id
end

return function(t)
	t.test("placement checks faction, permission, territory, zone and cap", function()
		local e = FacilityEngine.new({ types = TYPES, config = CONFIG })
		t.expect(select(2, e:CanPlace("Shrine", "z1", A))).toBe("FactionNotAllowed")
		t.expect(select(2, e:CanPlace("Base", "z1", { faction = "FactionA", canBuild = false }))).toBe("MissingPermission")
		t.expect(select(2, e:CanPlace("Base", "z1", { faction = "FactionA", canBuild = true, buildOk = false }))).toBe("TerritoryDenied")
		t.expect(select(2, e:CanPlace("Base", "z1", { faction = "RogueA", canBuild = true }))).toBe("FactionNotAllowed")
		t.expect((e:Place("Base", "z1", nil, A, 0))).toBe(true)
		t.expect(select(2, e:CanPlace("Base", "z1", A))).toBe("ZoneOccupied")
		e:Place("Base", "z2", nil, A, 0)
		t.expect(select(2, e:CanPlace("Base", "z3", A))).toBe("FacilityCap")
	end)

	t.test("construction needs every material and all build work", function()
		local e = FacilityEngine.new({ types = TYPES, config = CONFIG })
		local _, id = e:Place("Base", "z1", nil, A, 0)
		t.expect(e:Snapshot(id).state).toBe("UnderConstruction")
		t.expect(e:Snapshot(id).health).toBe(100)
		local ok, took = e:Contribute(id, "FactionA", "Material.Common", 25)
		t.expect(ok).toBe(true)
		t.expect(took).toBe(10)
		t.expect(select(2, e:Contribute(id, "FactionA", "Material.Common", 1))).toBe("NotNeeded")
		t.expect(select(2, e:Contribute(id, "FactionB", "Material.Common", 1))).toBe("NotYourFacility")
		local _, finished = e:Work(id, "FactionA", 10)
		t.expect(finished).toBe(false)
		_, finished = e:Work(id, "FactionA", 10)
		t.expect(finished).toBe(true)
		t.expect(e:Snapshot(id).state).toBe("Operational")
		t.expect(e:Snapshot(id).health).toBe(1000)
	end)

	t.test("damage degrades, destroys, and repair restores", function()
		local e, id = built()
		t.expect(select(2, e:Damage(id, 400))).toBe("Operational")
		t.expect(e:IsFunctional(id)).toBe(true)
		t.expect(select(2, e:Damage(id, 200))).toBe("Damaged")
		t.expect(e:IsFunctional(id)).toBe(false)
		t.expect(select(2, e:Repair(id, "FactionA", 300))).toBe("Operational")
		t.expect(select(2, e:Repair(id, "FactionB", 1))).toBe("NotYourFacility")
		t.expect(select(2, e:Damage(id, 5000))).toBe("Destroyed")
		t.expect(select(2, e:Repair(id, "FactionA", 100))).toBe("CannotRepair")
		t.expect(select(2, e:Damage(id, 1))).toBe("Destroyed")
	end)

	t.test("a ruin can be rebuilt on its zone", function()
		local e, id = built()
		e:Damage(id, 5000)
		t.expect((e:CanPlace("Base", "z1", A))).toBe(true)
		local _, newId = e:Place("Base", "z1", nil, A, 1)
		t.expect(e:Get(id)).toBeNil()
		t.expect(e:Snapshot(newId).state).toBe("UnderConstruction")
	end)

	t.test("uncontested attackers capture after captureTime", function()
		local e, id = built()
		t.expect((e:CaptureTick(id, { FactionB = 2 }, 5))).toBe("Progress")
		t.expect(e:Snapshot(id).capture.progress).toBe(0.5)
		local event, owner = e:CaptureTick(id, { FactionB = 1 }, 5)
		t.expect(event).toBe("Captured")
		t.expect(owner).toBe("FactionB")
		t.expect(e:Snapshot(id).faction).toBe("FactionB")
		t.expect(e:Snapshot(id).capture).toBeNil()
	end)

	t.test("defenders contest, absence decays, locks freeze", function()
		local e, id = built()
		e:CaptureTick(id, { FactionB = 1 }, 4)
		t.expect((e:CaptureTick(id, { FactionB = 1, FactionA = 1 }, 4))).toBe("Contested")
		t.expect(e:Snapshot(id).capture.progress).toBe(0.4)
		e:CaptureTick(id, {}, 4)
		t.expect(e:Snapshot(id).capture.progress).toBe(0.2)
		e:CaptureTick(id, {}, 10)
		t.expect(e:Snapshot(id).capture).toBeNil()
		e:CaptureTick(id, { FactionB = 1 }, 4)
		t.expect(e:CaptureTick(id, { FactionB = 1 }, 100, false)).toBeNil()
		t.expect(e:Snapshot(id).faction).toBe("FactionA")
		t.expect(e:CaptureTick(id, { RogueA = 3 }, 100)).toBeNil()
	end)

	t.test("non-capturable and unfinished facilities can't be captured", function()
		local e = FacilityEngine.new({ types = TYPES, config = CONFIG })
		local _, id = e:Place("Base", "z1", nil, A, 0)
		t.expect(e:CaptureTick(id, { FactionB = 1 }, 100)).toBeNil()
		local _, sid = e:Place("Shrine", "z2", nil, { faction = "FactionB", canBuild = true }, 0)
		e:FinishNow(sid)
		t.expect(e:CaptureTick(sid, { FactionA = 1 }, 100)).toBeNil()
	end)

	t.test("stations come from provides", function()
		local e, id = built()
		t.expect(e:StationsOf(id)).toEqual({ "Forge" })
	end)

	t.test("state survives save and load without id collisions", function()
		local e, id = built()
		e:Damage(id, 600)
		local loaded = FacilityEngine.new({ types = TYPES, config = CONFIG })
		loaded:Load(e:Serialize())
		t.expect(loaded:Snapshot(id).state).toBe("Damaged")
		t.expect(loaded:Snapshot(id).health).toBe(400)
		local _, newId = loaded:Place("Base", "z9", nil, A, 0)
		t.expect(newId ~= id).toBe(true)
	end)
end
