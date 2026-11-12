--[[
	EntitlementService (GDD §13.2, §13.3)

	Recognised authority, ownership and privileges, kept as records. Only the
	Loreteam (ManageEntitlements) can create, transfer, suspend, revoke or restore an
	entitlement, or move a challenge past "Submitted". The game never changes one by
	itself, with two exceptions that only mark records for Loreteam review:
		* the holder character's confirmed Permanent Death -> Vacated + needs review
		* the subject facility or territory changing hands in play -> needs review

	Players can see public entitlements and file challenges.

	Public API:
		EntitlementService:Holds(holderType, holderId, kind, subjectType, subjectId) -> boolean
		EntitlementService:GetEngine()

	Staff commands (ManageEntitlements):
		/ent list [review]
		/ent show <entId>
		/ent grant <kind> <holderType>:<id> <subjectType>:<id> ["notes"]
		/ent transfer <entId> <holderType>:<id> ["reason"]
		/ent suspend|revoke|restore <entId> ["reason"]
		/ent reviewed <entId>
		/challenge list [all]
		/challenge approve|schedule|reject <chlId>
		/challenge resolve <chlId> upheld|transferred ["reason"]
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local TerritoryConfig = require(ReplicatedStorage.Shared.Territory.TerritoryConfig)

local Production = script.Parent.Parent.Production
local Deps = require(Production.ProductionDeps)
local WorldStore = require(Production.WorldStore)
local EntitlementEngine = require(script.Parent.EntitlementEngine)
local FacilityService = require(script.Parent.FacilityService)
local TerritoryService = require(script.Parent.TerritoryService)

local STORE_KEY = "entitlements"
local MANAGE = "ManageEntitlements"

local EntitlementService = {}

local engine

local function save()
	WorldStore.Save(STORE_KEY, engine:Serialize())
end

local function parseRef(text)
	if type(text) ~= "string" then
		return nil
	end
	local kind, id = text:match("^(%a+):(.+)$")
	if not kind then
		return nil
	end
	return { type = kind, id = id }
end

local function describe(e)
	return ("%s %s %s:%s over %s:%s [%s]%s"):format(e.id, e.kind, e.holder.type, tostring(e.holder.id), e.subject.type,
		tostring(e.subject.id), e.status, e.needsReview and " NEEDS REVIEW" or "")
end

function EntitlementService:GetEngine()
	return engine
end

function EntitlementService:Holds(holderType, holderId, kind, subjectType, subjectId)
	return engine:Holds(holderType, holderId, kind, subjectType, subjectId)
end

-- Runs a staff write: permission check, then audit and save on success.
local function staffWrite(actor, action, details, fn)
	if not Deps.hasStaffPermission(actor, MANAGE) then
		return false, "NotPermitted"
	end
	local ok, result = fn(actor.UserId, os.time())
	if ok then
		Deps.audit(actor, action, details)
		save()
	end
	return ok, result
end

local function entCommand(player, args)
	local verb = args[1]
	if verb == nil or verb == "list" then
		local reviewOnly = args[2] == "review"
		local lines = {}
		for _, e in ipairs(engine:List(function(e)
			return not reviewOnly or e.needsReview
		end)) do
			table.insert(lines, describe(e))
		end
		return #lines > 0 and table.concat(lines, "\n") or "No entitlements."
	elseif verb == "show" then
		local e = engine:Get(args[2])
		if not e then
			return "Unknown entitlement."
		end
		local lines = { describe(e), "notes: " .. tostring(e.notes) }
		for _, h in ipairs(e.history) do
			table.insert(lines, ("  %s by %s at %s %s"):format(h.action, tostring(h.by), os.date("!%Y-%m-%d %H:%M", h.at), h.reason or ""))
		end
		return table.concat(lines, "\n")
	end
	local ok, result
	if verb == "grant" then
		local spec = { kind = args[2], holder = parseRef(args[3]), subject = parseRef(args[4]), notes = args[5] }
		ok, result = staffWrite(player, "Entitlement.Grant", spec, function(by, now)
			return engine:Create(by, spec, now)
		end)
	elseif verb == "transfer" then
		local holder = parseRef(args[3])
		ok, result = staffWrite(player, "Entitlement.Transfer", { id = args[2], holder = holder }, function(by, now)
			return engine:Transfer(by, args[2], holder, args[4], now)
		end)
	elseif verb == "suspend" or verb == "revoke" or verb == "restore" then
		local status = ({ suspend = "Suspended", revoke = "Revoked", restore = "Active" })[verb]
		ok, result = staffWrite(player, "Entitlement." .. status, { id = args[2] }, function(by, now)
			return engine:SetStatus(by, args[2], status, args[3], now)
		end)
	elseif verb == "reviewed" then
		ok, result = staffWrite(player, "Entitlement.Reviewed", { id = args[2] }, function(by, now)
			return engine:ClearReview(by, args[2], now)
		end)
	else
		return "Usage: /ent list|show|grant|transfer|suspend|revoke|restore|reviewed"
	end
	if not ok then
		return "Failed: " .. tostring(result)
	end
	return "Done" .. (type(result) == "string" and (" (" .. result .. ")") or "")
end

local function challengeCommand(player, args)
	local verb = args[1]
	if verb == nil or verb == "list" then
		local lines = {}
		for _, c in ipairs(engine:ListChallenges(args[2] ~= "all")) do
			table.insert(lines, ("%s on %s by %s:%s via %s [%s]%s %s"):format(c.id, c.entitlementId, c.challenger.type,
				tostring(c.challenger.id), c.method, c.status, c.outcome and (" " .. c.outcome) or "", c.notes or ""))
		end
		return #lines > 0 and table.concat(lines, "\n") or "No challenges."
	end
	local ok, err
	if verb == "approve" or verb == "schedule" or verb == "reject" then
		local status = ({ approve = "Approved", schedule = "Scheduled", reject = "Rejected" })[verb]
		ok, err = staffWrite(player, "Challenge." .. status, { id = args[2] }, function(by, now)
			return engine:SetChallengeStatus(by, args[2], status, now)
		end)
	elseif verb == "resolve" then
		local outcome = ({ upheld = "Upheld", transferred = "Transferred" })[args[3] or ""]
		ok, err = staffWrite(player, "Challenge.Resolved", { id = args[2], outcome = outcome }, function(by, now)
			return engine:ResolveChallenge(by, args[2], outcome, args[4], now)
		end)
	else
		return "Usage: /challenge list [all] | approve|schedule|reject <id> | resolve <id> upheld|transferred"
	end
	return ok and "Done" or ("Failed: " .. tostring(err))
end

local function registerCommands()
	local StaffCommandService = Deps.service("StaffCommandService")
	if not StaffCommandService or not StaffCommandService.RegisterCommand then
		return
	end
	local function guarded(fn)
		return function(player, args)
			if not Deps.hasStaffPermission(player, MANAGE) then
				return "Not permitted."
			end
			return fn(player, args)
		end
	end
	StaffCommandService:RegisterCommand("ent", {
		usage = {
			"/ent list [review]",
			"/ent show <entId>",
			'/ent grant <kind> <holderType>:<id> <subjectType>:<id> ["notes"]',
			'/ent transfer <entId> <holderType>:<id> ["reason"]',
			'/ent suspend|revoke|restore <entId> ["reason"]',
			"/ent reviewed <entId>",
		},
		permissions = { MANAGE },
		run = guarded(entCommand),
	})
	StaffCommandService:RegisterCommand("challenge", {
		usage = { "/challenge list [all]", "/challenge approve|schedule|reject <id>", '/challenge resolve <id> upheld|transferred ["reason"]' },
		permissions = { MANAGE },
		run = guarded(challengeCommand),
	})
end

local function flag(subjectType, subjectId, reason)
	local ids = engine:FlagSubject(subjectType, subjectId, reason, os.time())
	if #ids > 0 then
		Deps.audit(nil, "Entitlement.FlaggedForReview", { subject = subjectType .. ":" .. tostring(subjectId), ids = ids, reason = reason })
		save()
	end
end

function EntitlementService:Init()
	engine = EntitlementEngine.new({ maxOpenChallenges = TerritoryConfig.MaxOpenChallengesPerCharacter })
	registerCommands()
end

function EntitlementService:Start()
	engine:Load(WorldStore.Load(STORE_KEY))

	local PermadeathService = Deps.service("PermadeathService")
	if PermadeathService then
		PermadeathService.Permadeath:Connect(function(_, _, characterId)
			local ids = engine:VacateHolder("character", characterId, os.time())
			if #ids > 0 then
				Deps.audit(nil, "Entitlement.Vacated", { characterId = characterId, ids = ids })
				save()
			end
		end)
	end
	FacilityService.OwnerChanged:Connect(function(facilityId, newFaction, oldFaction, source)
		flag("facility", facilityId, ("%s: %s -> %s"):format(source, tostring(oldFaction), tostring(newFaction)))
	end)
	TerritoryService.ControllerChanged:Connect(function(key, newFaction, oldFaction, source)
		flag("territory", key, ("%s: %s -> %s"):format(source, tostring(oldFaction), tostring(newFaction)))
	end)

	Net.OnInvoke("EntitlementList", function()
		local out = {}
		for _, e in ipairs(engine:List(function(e)
			return e.status == "Active" or e.status == "Vacated"
		end)) do
			table.insert(out, { id = e.id, kind = e.kind, holder = e.holder, subject = e.subject, status = e.status })
		end
		return out
	end, { rateLimit = 2 })

	Net.OnInvoke("ChallengeSubmit", function(player, entitlementId, method, notes)
		if type(entitlementId) ~= "string" or type(method) ~= "string" or (notes ~= nil and type(notes) ~= "string") then
			return false, "BadRequest"
		end
		local character = Deps.character(player)
		if not character then
			return false, "NoLivingCharacter"
		end
		local ok, result = engine:SubmitChallenge(player.UserId, {
			entitlementId = entitlementId,
			challenger = { type = "character", id = character.id },
			method = method,
			notes = notes,
		}, os.time())
		if ok then
			Deps.audit(player, "Challenge.Submitted", { id = result, entitlementId = entitlementId, method = method, characterId = character.id })
			save()
		end
		return ok, result
	end, { rateLimit = 1 })
end

return EntitlementService
