--!strict
-- Official PD event control (GDD §3, §19.8). Every event-gated system asks
-- this service whether a PD is running.
--
-- Queries (safe to call any time after Init):
--   PDEventService:GetActiveEvent()   -> nil | EventSnapshot   (nil only when no event exists; paused events are returned)
--   PDEventService:IsActive()         -> boolean  (event exists AND is not paused; use this to gate trading, looting, PD deaths)
--   PDEventService:GetState()         -> "Inactive" | "Active" | "Paused"
--   PDEventService:GetPhase()         -> phase name or nil
--   PDEventService:IsPlayerInActiveEvent(player) -> boolean
--   PDEventService:WasActiveAt(timestamp) -> boolean  (was the current event Active at os.time() `timestamp`?)
--   PDEventService:GetRecord()        -> deep copy of the full EventRecord (windows, logs) or nil
--   PDEventService:GetHistory(limit?) -> { summary of past events }, newest first
--
-- Staff actions (permission-checked, audited, return (ok, err)):
--   :StartEvent(actor, name, phase?)        [ControlPDEvent]
--   :PauseEvent(actor, reason?)             [PausePDEvent]
--   :ResumeEvent(actor)                     [PausePDEvent]
--   :SetPhase(actor, phase)                 [ControlPDEvent]
--   :EndEvent(actor, summary?, force?)      [ControlPDEvent]
--
-- Signals, each fired with the EventSnapshot after the change:
--   EventStarted(event), EventPaused(event), EventResumed(event), EventEnded(event),
--   PhaseChanged(event, oldPhase, newPhase)
--
-- Clients can read ReplicatedStorage attributes PDState, PDPhase, PDEventId, PDEventName.
--
-- The authoritative record lives in a DataStore and every transition is an
-- UpdateAsync applied to the stored copy, so two servers can never both start
-- an event. Other servers are told through MessagingService and reload.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PDPhases = require(ReplicatedStorage.Shared.PDEvent.PDPhases)
local Permissions = require(ReplicatedStorage.Shared.Staff.Permissions)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Table = require(ReplicatedStorage.Shared.Util.Table)

local AccessGateService = require(script.Parent.Parent.Staff.AccessGateService)
local AuditLogService = require(script.Parent.Parent.Staff.AuditLogService)
local StaffConfig = require(script.Parent.Parent.Staff.StaffConfig)
local StaffService = require(script.Parent.Parent.Staff.StaffService)
local StateMachine = require(script.Parent.PDEventStateMachine)

type EventRecord = StateMachine.EventRecord

export type EventSnapshot = {
	id: string,
	name: string,
	state: string,
	paused: boolean,
	phase: string,
	startedAt: number,
	startedBy: number,
}

local State = PDPhases.State
local P = Permissions.Permission

local CURRENT_KEY = "Current"
local HISTORY_KEY = "History"
local HEARTBEAT_KEY = "Heartbeats"
local HISTORY_LIMIT = 100
local HEARTBEAT_INTERVAL = 60
local HEARTBEAT_STALE = 150

local PDEventService = {}

PDEventService.EventStarted = Signal.new()
PDEventService.EventPaused = Signal.new()
PDEventService.EventResumed = Signal.new()
PDEventService.EventEnded = Signal.new()
PDEventService.PhaseChanged = Signal.new()

local store: DataStore? = nil
local current: EventRecord? = nil
local snapshot: EventSnapshot? = nil
local pendingDeathCounter: ((eventId: string) -> number)? = nil

local function makeSnapshot(record: EventRecord?): EventSnapshot?
	if record == nil or record.state == State.Inactive then
		return nil
	end
	return table.freeze({
		id = record.id,
		name = record.name,
		state = record.state,
		paused = record.state == State.Paused,
		phase = record.phase,
		startedAt = record.startedAt,
		startedBy = record.startedBy,
	})
end

local function replicate()
	ReplicatedStorage:SetAttribute("PDState", if snapshot then snapshot.state else State.Inactive)
	ReplicatedStorage:SetAttribute("PDPhase", if snapshot then snapshot.phase else nil)
	ReplicatedStorage:SetAttribute("PDEventId", if snapshot then snapshot.id else nil)
	ReplicatedStorage:SetAttribute("PDEventName", if snapshot then snapshot.name else nil)
end

-- Installs `newRecord` as the local copy and fires the signals implied by the
-- difference. `silent` is used for the first load on boot.
local function applyLocal(newRecord: EventRecord?, silent: boolean?)
	local old = current
	current = newRecord
	snapshot = makeSnapshot(newRecord)
	replicate()
	if silent then
		return
	end

	local oldLive = old ~= nil and old.state ~= State.Inactive
	local newLive = newRecord ~= nil and newRecord.state ~= State.Inactive

	if oldLive and (not newLive or (old :: EventRecord).id ~= (newRecord :: EventRecord).id) then
		-- Fire with the old event's details and its final (Inactive) state.
		local prev = old :: EventRecord
		local endedSnap = table.freeze({
			id = prev.id,
			name = prev.name,
			state = State.Inactive,
			paused = false,
			phase = prev.phase,
			startedAt = prev.startedAt,
			startedBy = prev.startedBy,
		})
		PDEventService.EventEnded:Fire(endedSnap)
		oldLive = false
	end

	if not newLive then
		return
	end
	local rec = newRecord :: EventRecord
	if not oldLive then
		PDEventService.EventStarted:Fire(snapshot)
		if rec.state == State.Paused then
			PDEventService.EventPaused:Fire(snapshot)
		end
		return
	end

	local prev = old :: EventRecord
	if prev.phase ~= rec.phase then
		PDEventService.PhaseChanged:Fire(snapshot, prev.phase, rec.phase)
	end
	if prev.state == State.Active and rec.state == State.Paused then
		PDEventService.EventPaused:Fire(snapshot)
	elseif prev.state == State.Paused and rec.state == State.Active then
		PDEventService.EventResumed:Fire(snapshot)
	end
end

local function publish()
	task.spawn(function()
		pcall(MessagingService.PublishAsync, MessagingService, StaffConfig.PDEventTopic, game.JobId)
	end)
end

-- Applies `mutate` to the authoritative record. `mutate` receives a copy of the
-- stored record and returns (newRecord, err). It must not yield: UpdateAsync
-- may call it more than once.
local function commit(mutate: (EventRecord?) -> (EventRecord?, string?)): (boolean, string?, EventRecord?)
	local mutateErr: string? = nil
	local result: EventRecord? = nil

	if store then
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(CURRENT_KEY, function(stored: EventRecord?)
				mutateErr = nil
				local newRecord, e = mutate(stored)
				if e then
					mutateErr = e
					return nil -- cancels the write
				end
				result = newRecord
				return newRecord
			end)
		end)
		if not ok then
			return false, `Could not save the PD event state, nothing changed: {err}`, nil
		end
	else
		local copy: EventRecord? = if current then Table.deepCopy(current) :: any else nil
		local newRecord, e = mutate(copy)
		mutateErr = e
		result = newRecord
	end

	if mutateErr then
		return false, mutateErr, nil
	end
	applyLocal(result)
	publish()
	return true, nil, result
end

local function archive(record: EventRecord)
	if store == nil then
		return
	end
	task.spawn(function()
		local s = store :: DataStore
		pcall(s.SetAsync, s, "Event_" .. record.id, record)
		pcall(s.UpdateAsync, s, HISTORY_KEY, function(list: { any }?)
			local history = list or {}
			table.insert(history, 1, {
				id = record.id,
				name = record.name,
				startedAt = record.startedAt,
				endedAt = record.endedAt,
				startedBy = record.startedBy,
				endedBy = record.endedBy,
				summary = record.summary,
			})
			while #history > HISTORY_LIMIT do
				table.remove(history)
			end
			return history
		end)
	end)
end

local function newEventId(now: number): string
	local suffix = string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 6)
	return `PD-{os.date("!%Y%m%d", now)}-{suffix}`
end

--------------------------------------------------------------------------
-- Queries

function PDEventService:GetActiveEvent(): EventSnapshot?
	return snapshot
end

function PDEventService:IsActive(): boolean
	return snapshot ~= nil and snapshot.state == State.Active
end

function PDEventService:GetState(): string
	return if snapshot then snapshot.state else State.Inactive
end

function PDEventService:GetPhase(): string?
	return if snapshot then snapshot.phase else nil
end

function PDEventService:IsPlayerInActiveEvent(player: Player): boolean
	return PDEventService:IsActive() and player.Parent == Players and AccessGateService:IsAllowed(player)
end

function PDEventService:WasActiveAt(timestamp: number): boolean
	return StateMachine.WasActiveAt(current, timestamp)
end

function PDEventService:GetRecord(): EventRecord?
	if current == nil or current.state == State.Inactive then
		return nil
	end
	return Table.deepCopy(current :: EventRecord) :: any
end

function PDEventService:GetHistory(limit: number?): { any }
	if store == nil then
		return {}
	end
	local ok, list = pcall((store :: DataStore).GetAsync, store, HISTORY_KEY)
	if not ok or type(list) ~= "table" then
		return {}
	end
	local out = {}
	for i = 1, math.min(#list, limit or 10) do
		out[i] = list[i]
	end
	return out
end

-- ModerationService registers this so EndEvent can refuse while death
-- reports are unreviewed. Kept as a callback to avoid a require cycle.
function PDEventService:SetPendingDeathCounter(fn: (eventId: string) -> number)
	pendingDeathCounter = fn
end

--------------------------------------------------------------------------
-- Staff actions

function PDEventService:StartEvent(actor: Player, name: string, phase: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.ControlPDEvent)
	if not allowed then
		return false, permErr
	end
	local now = os.time()
	local id = newEventId(now)
	local ok, err, record = commit(function(stored)
		return StateMachine.Start(stored, id, name, actor.UserId, now, phase)
	end)
	if ok and record then
		AuditLogService:Record(actor.UserId, "PD.Start", nil, { eventId = record.id, name = record.name, phase = record.phase })
	end
	return ok, err
end

function PDEventService:PauseEvent(actor: Player, reason: string?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.PausePDEvent)
	if not allowed then
		return false, permErr
	end
	local now = os.time()
	local ok, err, record = commit(function(stored)
		local okPause, e = StateMachine.Pause(stored, actor.UserId, now, reason)
		return if okPause then stored else nil, e
	end)
	if ok and record then
		AuditLogService:Record(actor.UserId, "PD.Pause", nil, { eventId = record.id, reason = reason })
	end
	return ok, err
end

function PDEventService:ResumeEvent(actor: Player): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.PausePDEvent)
	if not allowed then
		return false, permErr
	end
	local now = os.time()
	local ok, err, record = commit(function(stored)
		local okResume, e = StateMachine.Resume(stored, actor.UserId, now)
		return if okResume then stored else nil, e
	end)
	if ok and record then
		AuditLogService:Record(actor.UserId, "PD.Resume", nil, { eventId = record.id })
	end
	return ok, err
end

function PDEventService:SetPhase(actor: Player, phase: string): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.ControlPDEvent)
	if not allowed then
		return false, permErr
	end
	local normalized = PDPhases.Normalize(phase) or phase
	local now = os.time()
	local oldPhase: string? = nil
	local ok, err, record = commit(function(stored)
		local old, e = StateMachine.SetPhase(stored, normalized, actor.UserId, now)
		oldPhase = old
		return if old then stored else nil, e
	end)
	if ok and record then
		AuditLogService:Record(actor.UserId, "PD.Phase", nil, { eventId = record.id, from = oldPhase, to = normalized })
	end
	return ok, err
end

function PDEventService:EndEvent(actor: Player, summary: string?, force: boolean?): (boolean, string?)
	local allowed, permErr = StaffService:Require(actor, P.ControlPDEvent)
	if not allowed then
		return false, permErr
	end
	-- Count pending reports before entering UpdateAsync (the counter may yield).
	local pending = 0
	if current and pendingDeathCounter then
		local okCount, count = pcall(pendingDeathCounter, current.id)
		pending = if okCount and type(count) == "number" then count else 0
	end
	local now = os.time()
	local ok, err, record = commit(function(stored)
		local okEnd, e = StateMachine.End(stored, actor.UserId, now, summary, pending, force)
		return if okEnd then stored else nil, e
	end)
	if ok and record then
		AuditLogService:Record(actor.UserId, "PD.End", nil, {
			eventId = record.id,
			summary = record.summary,
			forced = force == true and pending > 0,
			pendingDeathReports = pending,
		})
		archive(record)
	end
	return ok, err
end

--------------------------------------------------------------------------
-- Lifecycle

local function reload()
	if store == nil then
		return
	end
	local ok, stored = pcall((store :: DataStore).GetAsync, store, CURRENT_KEY)
	if ok then
		applyLocal(stored)
	end
end

-- Heartbeats let a booting server tell "the only server crashed" (pause the
-- event) apart from "another server is still running it" (leave it alone).
local function otherServersAlive(now: number): boolean
	if store == nil then
		return false
	end
	local ok, beats = pcall((store :: DataStore).GetAsync, store, HEARTBEAT_KEY)
	if not ok or type(beats) ~= "table" then
		return false
	end
	for jobId, at in beats do
		if jobId ~= game.JobId and type(at) == "number" and now - at < HEARTBEAT_STALE then
			return true
		end
	end
	return false
end

local function writeHeartbeat(remove: boolean?)
	if store == nil then
		return
	end
	pcall((store :: DataStore).UpdateAsync, store, HEARTBEAT_KEY, function(beats: { [string]: number }?)
		local now = os.time()
		local out: { [string]: number } = {}
		for jobId, at in beats or {} do
			if now - at < HEARTBEAT_STALE then
				out[jobId] = at
			end
		end
		out[game.JobId] = if remove then nil else now
		return out
	end)
end

local function autoPause(reason: string)
	local now = os.time()
	local ok, _, record = commit(function(stored)
		if stored == nil or stored.state ~= State.Active then
			return nil, "not active"
		end
		StateMachine.Pause(stored, 0, now, reason)
		return stored, nil
	end)
	if ok and record then
		AuditLogService:Record(0, "PD.Pause", nil, { eventId = record.id, reason = reason })
	end
end

function PDEventService:Init()
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, StaffConfig.DataStores.PDEvent)
	if ok then
		store = result
	end
	replicate()

	-- PD deaths may be confirmed while the event is Active or Paused (a pause
	-- for review is normal); only Inactive refuses.
	local okPermadeath, PermadeathService = pcall(require, script.Parent.Parent.PermadeathService)
	if okPermadeath then
		PermadeathService:SetPdEventProvider(function()
			return if snapshot then snapshot.id else nil
		end)
	else
		warn("[PDEventService] PermadeathService not found; PD deaths cannot be confirmed.")
	end

	-- Block switching away from a living character while an event exists, so
	-- players cannot dodge a PD by changing characters. Selecting a character
	-- when none is active (e.g. after a confirmed death) is always allowed.
	local okCharacter, CharacterService = pcall(require, script.Parent.Parent.CharacterService)
	if okCharacter then
		CharacterService:RegisterSwitchGuard("PDEvent", function(player: Player, fromId: string?, _toId: string?)
			if snapshot == nil or fromId == nil then
				return true, nil
			end
			if not CharacterService:IsAlive(player, fromId) then
				return true, nil
			end
			return false, "You cannot switch characters while a PD event is running."
		end)
	end
end

function PDEventService:Start()
	if store then
		-- Probe API access. In Studio without API access, fall back to memory.
		local okProbe, stored = pcall((store :: DataStore).GetAsync, store, CURRENT_KEY)
		if not okProbe then
			warn(`[PDEventService] DataStore unavailable ({stored}); PD state is kept in memory for this server only.`)
			store = nil
		else
			local now = os.time()
			if stored and stored.state == State.Active and not otherServersAlive(now) then
				-- The last server running the event went down. Bring it back paused.
				applyLocal(stored, true)
				autoPause("Server restarted during the event")
			else
				applyLocal(stored, true)
			end
		end
	end

	if store then
		task.spawn(function()
			local okSub, err = pcall(function()
				MessagingService:SubscribeAsync(StaffConfig.PDEventTopic, function(message)
					if message.Data ~= game.JobId then
						reload()
					end
				end)
			end)
			if not okSub then
				warn(`[PDEventService] Cross-server sync unavailable: {err}`)
			end
		end)

		task.spawn(function()
			while true do
				writeHeartbeat()
				task.wait(HEARTBEAT_INTERVAL)
			end
		end)

		game:BindToClose(function()
			writeHeartbeat(true)
			if PDEventService:IsActive() and not otherServersAlive(os.time()) then
				autoPause("Last server shut down during the event")
			end
		end)
	end
end

return PDEventService
