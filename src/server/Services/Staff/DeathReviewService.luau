--!strict
-- Moderator confirmation of Permanent Death (GDD §3.4, §16.3 step 1).
--
-- Combat reports every character death here. Deaths outside an Active window
-- of the current PD event are not PD deaths and are ignored. The rest wait in
-- a queue until a moderator confirms or dismisses them. Confirming hands the
-- death to core's PermadeathService, which runs the reset and satchel pipeline.
--
--   DeathReviewService:ReportDeath({ userId, characterId, killerUserId?, occurredAt?, cause?, location? })
--       -> (reportId?, reason?)          called by combat, no permission needed (server only)
--   DeathReviewService:ListReports(eventId?, status?) -> { Report }   (newest first)
--   DeathReviewService:GetPendingCount(eventId) -> number
--   DeathReviewService:ConfirmReport(actor, reportId, reason)  -> (ok, err)  [ConfirmDeath]
--   DeathReviewService:DismissReport(actor, reportId, reason)  -> (ok, err)  [ConfirmDeath]
--   DeathReviewService:ConfirmDirect(actor, userId, characterId?, reason) -> (ok, err)  [ConfirmDeath]
--       for a death a moderator witnessed that combat did not report (e.g. a roleplay execution)
--   DeathReviewService.ReportAdded(report), .ReportResolved(report)

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local AuditLogService = require(script.Parent.AuditLogService)
local StaffConfig = require(script.Parent.StaffConfig)
local StaffNotify = require(script.Parent.StaffNotify)
local StaffService = require(script.Parent.StaffService)

-- Required lazily in Init to keep the module graph acyclic.
local PDEventService: any = nil
local PermadeathService: any = nil
local CharacterService: any = nil

export type Report = {
	id: string,
	eventId: string,
	userId: number,
	characterId: string,
	killerUserId: number?,
	occurredAt: number,
	cause: string?,
	reportedAt: number,
	status: "Pending" | "Confirmed" | "Dismissed",
	reviewedBy: number?,
	reviewedAt: number?,
	reviewNote: string?,
}

export type DeathInput = {
	userId: number,
	characterId: string,
	killerUserId: number?,
	occurredAt: number?,
	cause: string?,
	location: CFrame?,
}

local P = Permissions.Permission
local MAX_REPORTS_PER_EVENT = 2000

local DeathReviewService = {}

DeathReviewService.ReportAdded = Signal.new()
DeathReviewService.ReportResolved = Signal.new()

local store: DataStore? = nil
-- eventId -> reportId -> Report (this server's view; refreshed from the store on list)
local reportsByEvent: { [string]: { [string]: Report } } = {}
-- CFrames cannot be saved, so death locations stay in memory for the satchel.
local locations: { [string]: CFrame } = {}

local function storeKey(eventId: string): string
	return "Reports_" .. eventId
end

local function cache(report: Report)
	reportsByEvent[report.eventId] = reportsByEvent[report.eventId] or {}
	reportsByEvent[report.eventId][report.id] = report
end

local function persist(report: Report)
	if store == nil then
		return
	end
	task.spawn(function()
		local ok, err = pcall((store :: DataStore).UpdateAsync, store, storeKey(report.eventId), function(list: { [string]: Report }?)
			local map = list or {}
			map[report.id] = report
			return map
		end)
		if not ok then
			warn(`[DeathReviewService] Could not save report {report.id}: {err}`)
		end
	end)
end

local function loadEvent(eventId: string): { [string]: Report }
	if store ~= nil then
		local ok, map = pcall((store :: DataStore).GetAsync, store, storeKey(eventId))
		if ok and type(map) == "table" then
			for _, report in map do
				local local_ = reportsByEvent[eventId] and reportsByEvent[eventId][report.id]
				-- Prefer a locally newer status (the save may still be in flight).
				if local_ == nil or local_.status == "Pending" then
					cache(report)
				end
			end
		end
	end
	return reportsByEvent[eventId] or {}
end

local function findReport(reportId: string): Report?
	for _, map in reportsByEvent do
		if map[reportId] then
			return map[reportId]
		end
	end
	local event = PDEventService and PDEventService:GetActiveEvent()
	if event then
		return loadEvent(event.id)[reportId]
	end
	return nil
end

local function trimReason(reason: string?): string?
	if type(reason) ~= "string" then
		return nil
	end
	local text = string.gsub(reason, "^%s*(.-)%s*$", "%1")
	if text == "" then
		return nil
	end
	return string.sub(text, 1, 300)
end

--------------------------------------------------------------------------

function DeathReviewService:ReportDeath(input: DeathInput): (string?, string?)
	if type(input) ~= "table" or type(input.userId) ~= "number" or type(input.characterId) ~= "string" then
		return nil, "Invalid death report."
	end
	local event = PDEventService:GetActiveEvent()
	local occurredAt = input.occurredAt or os.time()
	if event == nil or not PDEventService:WasActiveAt(occurredAt) then
		return nil, "NotPDDeath"
	end
	-- One pending report per character per event.
	for _, existing in reportsByEvent[event.id] or {} do
		if existing.characterId == input.characterId and existing.status == "Pending" then
			return existing.id, "AlreadyReported"
		end
	end
	local count = 0
	for _ in reportsByEvent[event.id] or {} do
		count += 1
	end
	if count >= MAX_REPORTS_PER_EVENT then
		return nil, "TooManyReports"
	end

	local report: Report = {
		id = string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 8),
		eventId = event.id,
		userId = input.userId,
		characterId = input.characterId,
		killerUserId = input.killerUserId,
		occurredAt = occurredAt,
		cause = trimReason(input.cause),
		reportedAt = os.time(),
		status = "Pending",
	}
	if input.location then
		locations[report.id] = input.location
	end
	cache(report)
	persist(report)
	AuditLogService:Record(0, "Death.Reported", report.userId, {
		reportId = report.id,
		eventId = report.eventId,
		characterId = report.characterId,
		killer = report.killerUserId,
		cause = report.cause,
	})
	DeathReviewService.ReportAdded:Fire(report)

	local victim = Players:GetPlayerByUserId(report.userId)
	local victimName = if victim then victim.Name else tostring(report.userId)
	StaffNotify.ToPermission(
		P.ConfirmDeath,
		`PD death reported: {victimName} (report {report.id}). Review with /death confirm {report.id} <reason> or /death dismiss {report.id} <reason>.`
	)
	return report.id, nil
end

function DeathReviewService:ListReports(eventId: string?, status: string?): { Report }
	local id = eventId
	if id == nil then
		local event = PDEventService:GetActiveEvent()
		id = event and event.id
	end
	if id == nil then
		return {}
	end
	local out: { Report } = {}
	for _, report in loadEvent(id) do
		if status == nil or report.status == status then
			table.insert(out, report)
		end
	end
	table.sort(out, function(a, b)
		return a.reportedAt > b.reportedAt
	end)
	return out
end

function DeathReviewService:GetPendingCount(eventId: string): number
	local n = 0
	for _, report in loadEvent(eventId) do
		if report.status == "Pending" then
			n += 1
		end
	end
	return n
end

local function resolve(report: Report, actor: Player, status: "Confirmed" | "Dismissed", note: string)
	report.status = status
	report.reviewedBy = actor.UserId
	report.reviewedAt = os.time()
	report.reviewNote = note
	locations[report.id] = nil
	persist(report)
	DeathReviewService.ReportResolved:Fire(report)
end

local function runPermadeath(actor: Player, userId: number, characterId: string, eventId: string, reason: string, location: CFrame?): (boolean, string?)
	local ok, err = PermadeathService:ConfirmDeath({
		userId = userId,
		characterId = characterId,
		pdEventId = eventId,
		confirmedBy = actor.UserId,
		reason = reason,
		location = location,
	})
	if not ok then
		return false, `Permanent Death was not applied: {tostring(err)}`
	end
	return true, nil
end

function DeathReviewService:ConfirmReport(actor: Player, reportId: string, reason: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.ConfirmDeath)
	if not allowed then
		return false, permErr
	end
	local note = trimReason(reason)
	if note == nil then
		return false, "Record the circumstances of the death as the reason (GDD §3.4)."
	end
	local report = findReport(reportId)
	if report == nil then
		return false, `No death report with id {reportId}.`
	end
	if report.status ~= "Pending" then
		return false, `Report {reportId} was already {string.lower(report.status)}.`
	end
	local event = PDEventService:GetActiveEvent()
	if event == nil or event.id ~= report.eventId then
		return false, "That death belongs to a PD event that has ended. It can no longer be confirmed."
	end
	if report.userId == actor.UserId then
		return false, "You cannot confirm your own character's death. Ask another moderator."
	end

	local ok, err = runPermadeath(actor, report.userId, report.characterId, report.eventId, note, locations[report.id])
	if not ok then
		AuditLogService:Record(actor.UserId, "Death.ConfirmFailed", report.userId, { reportId = report.id, error = err })
		return false, err
	end
	resolve(report, actor, "Confirmed", note)
	AuditLogService:Record(actor.UserId, "Death.Confirmed", report.userId, {
		reportId = report.id,
		eventId = report.eventId,
		characterId = report.characterId,
		reason = note,
	})
	return true, nil
end

function DeathReviewService:DismissReport(actor: Player, reportId: string, reason: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.ConfirmDeath)
	if not allowed then
		return false, permErr
	end
	local note = trimReason(reason)
	if note == nil then
		return false, "Give a reason for dismissing the report."
	end
	local report = findReport(reportId)
	if report == nil then
		return false, `No death report with id {reportId}.`
	end
	if report.status ~= "Pending" then
		return false, `Report {reportId} was already {string.lower(report.status)}.`
	end
	resolve(report, actor, "Dismissed", note)
	AuditLogService:Record(actor.UserId, "Death.Dismissed", report.userId, {
		reportId = report.id,
		eventId = report.eventId,
		characterId = report.characterId,
		reason = note,
	})
	return true, nil
end

function DeathReviewService:ConfirmDirect(actor: Player, userId: number, characterId: string?, reason: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.ConfirmDeath)
	if not allowed then
		return false, permErr
	end
	local note = trimReason(reason)
	if note == nil then
		return false, "Record the circumstances of the death as the reason (GDD §3.4)."
	end
	if userId == actor.UserId then
		return false, "You cannot confirm your own character's death. Ask another moderator."
	end
	local event = PDEventService:GetActiveEvent()
	if event == nil then
		return false, "There is no PD event. Deaths outside a PD are not permanent."
	end
	local charId = characterId
	if charId == nil then
		local target = Players:GetPlayerByUserId(userId)
		if target == nil then
			return false, "That player is not in this server. Give the character id explicitly."
		end
		charId = CharacterService:GetActiveCharacterId(target)
		if charId == nil then
			return false, "That player has no active character."
		end
	end

	local ok, err = runPermadeath(actor, userId, charId :: string, event.id, note, nil)
	if not ok then
		AuditLogService:Record(actor.UserId, "Death.ConfirmFailed", userId, { characterId = charId, error = err })
		return false, err
	end
	-- Close any pending report for the same character.
	for _, report in reportsByEvent[event.id] or {} do
		if report.characterId == charId and report.status == "Pending" then
			resolve(report, actor, "Confirmed", note)
		end
	end
	AuditLogService:Record(actor.UserId, "Death.Confirmed", userId, {
		eventId = event.id,
		characterId = charId,
		reason = note,
		direct = true,
	})
	return true, nil
end

function DeathReviewService:Init()
	PDEventService = require(script.Parent.Parent.PDEvent.PDEventService)
	PermadeathService = require(script.Parent.Parent.PermadeathService)
	CharacterService = require(script.Parent.Parent.CharacterService)

	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, StaffConfig.DataStores.Deaths)
	if ok then
		store = result
	end

	PDEventService:SetPendingDeathCounter(function(eventId: string)
		return DeathReviewService:GetPendingCount(eventId)
	end)

	PDEventService.EventEnded:Connect(function(event)
		-- Pending reports from an ended event can never be confirmed; drop the cache.
		reportsByEvent[event.id] = nil
		for id in locations do
			locations[id] = nil
		end
	end)
end

function DeathReviewService:Start()
	if store then
		local okProbe = pcall((store :: DataStore).GetAsync, store, "probe")
		if not okProbe then
			store = nil
		end
	end
end

return DeathReviewService
