local ServerScriptService = game:GetService("ServerScriptService")

local EntitlementEngine = require(ServerScriptService.Server.Services.Territory.EntitlementEngine)

local function withOne()
	local e = EntitlementEngine.new({ maxOpenChallenges = 2 })
	local _, id = e:Create(100, {
		kind = "FacilityControl",
		holder = { type = "character", id = "c1" },
		subject = { type = "facility", id = "fac-1" },
		notes = "Appointed",
	}, 1)
	return e, id
end

return function(t)
	t.test("create validates kind, holder and subject", function()
		local e = EntitlementEngine.new()
		t.expect(select(2, e:Create(1, { kind = "Nope", holder = { type = "character", id = "c" }, subject = { type = "facility", id = "f" } }, 0))).toBe("UnknownKind")
		t.expect(select(2, e:Create(1, { kind = "Leadership", holder = { type = "x", id = "c" }, subject = { type = "role", id = "r" } }, 0))).toBe("BadHolder")
		t.expect(select(2, e:Create(1, { kind = "Leadership", holder = { type = "character", id = "c" }, subject = { type = "x", id = "r" } }, 0))).toBe("BadSubject")
		local ok, id = e:Create(1, { kind = "Leadership", holder = { type = "character", id = "c" }, subject = { type = "role", id = "Leader" } }, 0)
		t.expect(ok).toBe(true)
		t.expect(e:Get(id).status).toBe("Active")
		t.expect(#e:Get(id).history).toBe(1)
	end)

	t.test("holds checks active entitlements only", function()
		local e, id = withOne()
		t.expect(e:Holds("character", "c1", "FacilityControl", "facility", "fac-1")).toBe(true)
		e:SetStatus(100, id, "Suspended", "Investigation", 2)
		t.expect(e:Holds("character", "c1", "FacilityControl", "facility", "fac-1")).toBe(false)
	end)

	t.test("death vacates and flags, never reassigns", function()
		local e, id = withOne()
		t.expect(e:VacateHolder("character", "c1", 5)).toEqual({ id })
		t.expect(e:Get(id).status).toBe("Vacated")
		t.expect(e:Get(id).needsReview).toBe(true)
		t.expect(e:Get(id).holder.id).toBe("c1")
	end)

	t.test("losing the subject in play only flags it", function()
		local e, id = withOne()
		t.expect(e:FlagSubject("facility", "fac-1", "Captured", 5)).toEqual({ id })
		t.expect(e:Get(id).status).toBe("Active")
		t.expect(e:Get(id).needsReview).toBe(true)
		e:ClearReview(100, id, 6)
		t.expect(e:Get(id).needsReview).toBe(false)
	end)

	t.test("challenges: submit limits", function()
		local e, id = withOne()
		local me = { type = "character", id = "c2" }
		t.expect(select(2, e:SubmitChallenge(2, { entitlementId = id, challenger = { type = "character", id = "c1" }, method = "Combat" }, 1))).toBe("AlreadyHolder")
		t.expect(select(2, e:SubmitChallenge(2, { entitlementId = id, challenger = me, method = "Dance" }, 1))).toBe("UnknownMethod")
		t.expect((e:SubmitChallenge(2, { entitlementId = id, challenger = me, method = "Combat" }, 1))).toBe(true)
		t.expect(select(2, e:SubmitChallenge(2, { entitlementId = id, challenger = me, method = "Political" }, 1))).toBe("AlreadyChallenging")
		local _, id2 = e:Create(100, { kind = "Leadership", holder = { type = "character", id = "c1" }, subject = { type = "role", id = "Leader" } }, 1)
		local _, id3 = e:Create(100, { kind = "Representative", holder = { type = "character", id = "c1" }, subject = { type = "role", id = "Envoy" } }, 1)
		t.expect((e:SubmitChallenge(2, { entitlementId = id2, challenger = me, method = "Leadership" }, 1))).toBe(true)
		t.expect(select(2, e:SubmitChallenge(2, { entitlementId = id3, challenger = me, method = "Leadership" }, 1))).toBe("TooManyChallenges")
	end)

	t.test("resolving with Transferred moves the entitlement in one step", function()
		local e, id = withOne()
		local _, cid = e:SubmitChallenge(2, { entitlementId = id, challenger = { type = "character", id = "c2" }, method = "Combat" }, 1)
		t.expect((e:SetChallengeStatus(100, cid, "Scheduled", 2))).toBe(true)
		t.expect((e:ResolveChallenge(100, cid, "Transferred", "Won the duel", 3))).toBe(true)
		t.expect(e:Get(id).holder.id).toBe("c2")
		t.expect(e:GetChallenge(cid).status).toBe("Resolved")
		t.expect(select(2, e:ResolveChallenge(100, cid, "Upheld", nil, 4))).toBe("ChallengeClosed")
	end)

	t.test("upheld and rejected challenges keep the holder", function()
		local e, id = withOne()
		local _, c1 = e:SubmitChallenge(2, { entitlementId = id, challenger = { type = "character", id = "c2" }, method = "Combat" }, 1)
		e:ResolveChallenge(100, c1, "Upheld", nil, 2)
		local _, c2 = e:SubmitChallenge(2, { entitlementId = id, challenger = { type = "character", id = "c2" }, method = "Combat" }, 3)
		e:SetChallengeStatus(100, c2, "Rejected", 4)
		t.expect(e:Get(id).holder.id).toBe("c1")
		t.expect(#e:ListChallenges(true)).toBe(0)
	end)

	t.test("records survive save and load without id collisions", function()
		local e, id = withOne()
		local loaded = EntitlementEngine.new()
		loaded:Load(e:Serialize())
		t.expect(loaded:Get(id).kind).toBe("FacilityControl")
		local _, newId = loaded:Create(1, { kind = "Leadership", holder = { type = "faction", id = "FactionA" }, subject = { type = "role", id = "Leader" } }, 0)
		t.expect(newId ~= id).toBe(true)
	end)
end
