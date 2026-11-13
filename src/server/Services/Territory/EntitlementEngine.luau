--[[
	EntitlementEngine

	Pure records for entitlements and challenges (GDD §13.2, §13.3). The game stores
	and reads these; it never creates, transfers or revokes one on its own. Every
	write here except SubmitChallenge, Vacate and FlagForReview is a staff action,
	and the service checks the Loreteam permission before calling it.

	Entitlement:
		{ id, kind, holder = {type, id}, subject = {type, id}, status, needsReview,
		  grantedBy, grantedAt, notes, history = { {action, by, at, reason} } }
	Challenge:
		{ id, entitlementId, challenger = {type, id}, method, status, outcome,
		  filedAt, filedBy, resolvedBy, resolvedAt, notes }
]]

local EntitlementEngine = {}
EntitlementEngine.__index = EntitlementEngine

EntitlementEngine.Kinds = {
	Leadership = true,
	FacilityControl = true,
	ResourceAccess = true,
	OperationAuthority = true,
	Representative = true,
	TerritoryControl = true,
}
EntitlementEngine.HolderTypes = { character = true, faction = true, group = true }
EntitlementEngine.SubjectTypes = { facility = true, territory = true, node = true, role = true, operation = true, other = true }
EntitlementEngine.Statuses = { Active = true, Suspended = true, Vacated = true, Revoked = true }
EntitlementEngine.Methods = {
	Combat = true,
	ResourceContribution = true,
	MilitaryOperation = true,
	Political = true,
	Leadership = true,
	SpecialTrial = true,
	Other = true,
}

local OPEN = { Submitted = true, Approved = true, Scheduled = true }

local function ref(t, allowed)
	return type(t) == "table" and allowed[t.type] == true and (type(t.id) == "string" or type(t.id) == "number")
end

function EntitlementEngine.new(deps)
	deps = deps or {}
	local counters = { ent = 0, chl = 0 }
	return setmetatable({
		_counters = counters,
		_ents = {},
		_challenges = {},
		_maxOpen = deps.maxOpenChallenges or 2,
		_newId = deps.newId or function(prefix)
			counters[prefix] = counters[prefix] + 1
			return ("%s_%06d"):format(prefix, counters[prefix])
		end,
	}, EntitlementEngine)
end

local function log(e, action, by, at, reason)
	table.insert(e.history, { action = action, by = by, at = at, reason = reason })
end

function EntitlementEngine:Get(id)
	return self._ents[id]
end

function EntitlementEngine:Create(actor, spec, now)
	if not EntitlementEngine.Kinds[spec.kind] then
		return false, "UnknownKind"
	end
	if not ref(spec.holder, EntitlementEngine.HolderTypes) then
		return false, "BadHolder"
	end
	if not ref(spec.subject, EntitlementEngine.SubjectTypes) then
		return false, "BadSubject"
	end
	local id = self._newId("ent")
	local e = {
		id = id,
		kind = spec.kind,
		holder = { type = spec.holder.type, id = spec.holder.id },
		subject = { type = spec.subject.type, id = spec.subject.id },
		status = "Active",
		needsReview = false,
		grantedBy = actor,
		grantedAt = now,
		notes = spec.notes,
		history = {},
	}
	log(e, "Created", actor, now, spec.notes)
	self._ents[id] = e
	return true, id
end

function EntitlementEngine:Transfer(actor, id, holder, reason, now)
	local e = self._ents[id]
	if not e then
		return false, "UnknownEntitlement"
	end
	if not ref(holder, EntitlementEngine.HolderTypes) then
		return false, "BadHolder"
	end
	e.holder = { type = holder.type, id = holder.id }
	e.status = "Active"
	e.needsReview = false
	log(e, "Transferred:" .. holder.type .. ":" .. tostring(holder.id), actor, now, reason)
	return true
end

function EntitlementEngine:SetStatus(actor, id, status, reason, now)
	local e = self._ents[id]
	if not e then
		return false, "UnknownEntitlement"
	end
	if not EntitlementEngine.Statuses[status] then
		return false, "UnknownStatus"
	end
	e.status = status
	if status == "Active" then
		e.needsReview = false
	end
	log(e, "Status:" .. status, actor, now, reason)
	return true
end

function EntitlementEngine:ClearReview(actor, id, now)
	local e = self._ents[id]
	if not e then
		return false, "UnknownEntitlement"
	end
	e.needsReview = false
	log(e, "Reviewed", actor, now)
	return true
end

-- System action on PD death: character-held entitlements become Vacated and flagged.
-- Nobody inherits them automatically. Returns the affected ids.
function EntitlementEngine:VacateHolder(holderType, holderId, now)
	local out = {}
	for id, e in pairs(self._ents) do
		if e.holder.type == holderType and e.holder.id == holderId and (e.status == "Active" or e.status == "Suspended") then
			e.status = "Vacated"
			e.needsReview = true
			log(e, "Vacated", 0, now, "Holder died")
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

-- System action when a subject changes hands in play (capture): flag only.
function EntitlementEngine:FlagSubject(subjectType, subjectId, reason, now)
	local out = {}
	for id, e in pairs(self._ents) do
		if e.subject.type == subjectType and e.subject.id == subjectId and e.status ~= "Revoked" then
			e.needsReview = true
			log(e, "FlaggedForReview", 0, now, reason)
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

-- Does this holder hold an active entitlement of kind over subject?
function EntitlementEngine:Holds(holderType, holderId, kind, subjectType, subjectId)
	for _, e in pairs(self._ents) do
		if e.status == "Active" and e.kind == kind and e.holder.type == holderType and e.holder.id == holderId
			and e.subject.type == subjectType and e.subject.id == subjectId then
			return true
		end
	end
	return false
end

function EntitlementEngine:List(filter)
	local out = {}
	for _, e in pairs(self._ents) do
		if not filter or filter(e) then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- Challenges ---------------------------------------------------------------

function EntitlementEngine:OpenChallengesBy(challengerType, challengerId)
	local n = 0
	for _, c in pairs(self._challenges) do
		if OPEN[c.status] and c.challenger.type == challengerType and c.challenger.id == challengerId then
			n = n + 1
		end
	end
	return n
end

-- Players may file a challenge; everything after that is a Loreteam action.
function EntitlementEngine:SubmitChallenge(filedBy, spec, now)
	local e = self._ents[spec.entitlementId]
	if not e then
		return false, "UnknownEntitlement"
	end
	if e.status == "Revoked" then
		return false, "NotChallengeable"
	end
	if not EntitlementEngine.Methods[spec.method] then
		return false, "UnknownMethod"
	end
	if not ref(spec.challenger, EntitlementEngine.HolderTypes) then
		return false, "BadChallenger"
	end
	if e.holder.type == spec.challenger.type and e.holder.id == spec.challenger.id then
		return false, "AlreadyHolder"
	end
	for _, c in pairs(self._challenges) do
		if OPEN[c.status] and c.entitlementId == e.id and c.challenger.type == spec.challenger.type and c.challenger.id == spec.challenger.id then
			return false, "AlreadyChallenging"
		end
	end
	if self:OpenChallengesBy(spec.challenger.type, spec.challenger.id) >= self._maxOpen then
		return false, "TooManyChallenges"
	end
	local notes = type(spec.notes) == "string" and spec.notes:sub(1, 500) or nil
	local id = self._newId("chl")
	self._challenges[id] = {
		id = id,
		entitlementId = e.id,
		challenger = { type = spec.challenger.type, id = spec.challenger.id },
		method = spec.method,
		status = "Submitted",
		filedAt = now,
		filedBy = filedBy,
		notes = notes,
	}
	return true, id
end

function EntitlementEngine:GetChallenge(id)
	return self._challenges[id]
end

-- status: "Approved" | "Scheduled" | "Rejected"
function EntitlementEngine:SetChallengeStatus(actor, id, status, now)
	local c = self._challenges[id]
	if not c then
		return false, "UnknownChallenge"
	end
	if not OPEN[c.status] then
		return false, "ChallengeClosed"
	end
	if status ~= "Approved" and status ~= "Scheduled" and status ~= "Rejected" then
		return false, "UnknownStatus"
	end
	c.status = status
	if status == "Rejected" then
		c.resolvedBy, c.resolvedAt = actor, now
	end
	return true
end

-- outcome "Upheld" keeps the holder; "Transferred" moves the entitlement to the
-- challenger in the same step, so the ruling and the change are one logged action.
function EntitlementEngine:ResolveChallenge(actor, id, outcome, reason, now)
	local c = self._challenges[id]
	if not c then
		return false, "UnknownChallenge"
	end
	if not OPEN[c.status] then
		return false, "ChallengeClosed"
	end
	if outcome ~= "Upheld" and outcome ~= "Transferred" then
		return false, "UnknownOutcome"
	end
	if outcome == "Transferred" then
		local ok, err = self:Transfer(actor, c.entitlementId, c.challenger, reason or ("Challenge " .. id), now)
		if not ok then
			return false, err
		end
	else
		log(self._ents[c.entitlementId], "ChallengeUpheld:" .. id, actor, now, reason)
	end
	c.status = "Resolved"
	c.outcome = outcome
	c.resolvedBy, c.resolvedAt = actor, now
	return true
end

function EntitlementEngine:ListChallenges(openOnly)
	local out = {}
	for _, c in pairs(self._challenges) do
		if not openOnly or OPEN[c.status] then
			table.insert(out, c)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function EntitlementEngine:Serialize()
	return { entitlements = self._ents, challenges = self._challenges }
end

function EntitlementEngine:Load(data)
	if type(data) ~= "table" then
		return
	end
	self._ents = data.entitlements or {}
	self._challenges = data.challenges or {}
	-- Keep new ids after the loaded ones.
	for _, pair in ipairs({ { "ent", self._ents }, { "chl", self._challenges } }) do
		for id in pairs(pair[2]) do
			local n = tonumber(tostring(id):match("_(%d+)$"))
			if n and n > self._counters[pair[1]] then
				self._counters[pair[1]] = n
			end
		end
	end
end

return EntitlementEngine
