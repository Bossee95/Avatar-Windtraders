--!strict
-- Pure PD event state machine. No Roblox services, so it can be unit tested
-- and so persistence/networking stay in PDEventService.
--
-- PD boundaries (GDD §19.8), as implemented here:
--   * A PD BEGINS when a Loreteam member starts it. State becomes Active.
--   * A PD PAUSES when Loreteam or Moderation pauses it, or when the server
--     restarts mid-event (the restored event comes back Paused, never Active).
--     While Paused, trading, satchel looting and PD deaths are all off.
--   * A PD RESUMES only by explicit staff action.
--   * A PD CONCLUDES when a Loreteam member ends it. Ending is refused while
--     death reports from this event are still awaiting moderator review,
--     unless forced. Ending removes the event; all event-gated systems stop.
--   * A death only counts as Permanent Death if it happened inside one of the
--     event's Active windows (WasActiveAt).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PDPhases = require(ReplicatedStorage.Shared.PDEvent.PDPhases)

local State = PDPhases.State
local Phase = PDPhases.Phase

export type ActiveWindow = { from: number, to: number? }
export type PhaseEntry = { phase: string, at: number, by: number }
export type PauseEntry = { at: number, by: number, reason: string, resumedAt: number?, resumedBy: number? }

export type EventRecord = {
	id: string,
	name: string,
	state: string,
	phase: string,
	startedAt: number,
	startedBy: number,
	endedAt: number?,
	endedBy: number?,
	summary: string?,
	activeWindows: { ActiveWindow },
	phaseLog: { PhaseEntry },
	pauseLog: { PauseEntry },
}

local PDEventStateMachine = {}

local MAX_NAME_LENGTH = 80
local MAX_TEXT_LENGTH = 500

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Creates a new Active event. `current` is the existing record, if any.
function PDEventStateMachine.Start(
	current: EventRecord?,
	id: string,
	name: string,
	actorUserId: number,
	now: number,
	initialPhase: string?
): (EventRecord?, string?)
	if current ~= nil and current.state ~= State.Inactive then
		return nil, `A PD event is already {string.lower(current.state)} ("{current.name}"). End it first.`
	end
	name = trim(name)
	if name == "" then
		return nil, "An event needs a name."
	end
	if #name > MAX_NAME_LENGTH then
		return nil, `Event names are limited to {MAX_NAME_LENGTH} characters.`
	end
	local phase = initialPhase or Phase.Preparation
	if not PDPhases.IsValidPhase(phase) then
		return nil, `Unknown phase "{tostring(initialPhase)}".`
	end
	local record: EventRecord = {
		id = id,
		name = name,
		state = State.Active,
		phase = phase,
		startedAt = now,
		startedBy = actorUserId,
		activeWindows = { { from = now } },
		phaseLog = { { phase = phase, at = now, by = actorUserId } },
		pauseLog = {},
	}
	return record, nil
end

function PDEventStateMachine.Pause(record: EventRecord?, actorUserId: number, now: number, reason: string?): (boolean, string?)
	if record == nil or record.state == State.Inactive then
		return false, "There is no PD event running."
	end
	if record.state == State.Paused then
		return false, "The PD event is already paused."
	end
	local text = trim(reason or "")
	if text == "" then
		text = "No reason given"
	end
	if #text > MAX_TEXT_LENGTH then
		text = string.sub(text, 1, MAX_TEXT_LENGTH)
	end
	record.state = State.Paused
	local window = record.activeWindows[#record.activeWindows]
	if window and window.to == nil then
		window.to = now
	end
	table.insert(record.pauseLog, { at = now, by = actorUserId, reason = text })
	return true, nil
end

function PDEventStateMachine.Resume(record: EventRecord?, actorUserId: number, now: number): (boolean, string?)
	if record == nil or record.state == State.Inactive then
		return false, "There is no PD event to resume."
	end
	if record.state ~= State.Paused then
		return false, "The PD event is not paused."
	end
	record.state = State.Active
	table.insert(record.activeWindows, { from = now })
	local pause = record.pauseLog[#record.pauseLog]
	if pause and pause.resumedAt == nil then
		pause.resumedAt = now
		pause.resumedBy = actorUserId
	end
	return true, nil
end

-- Phases are guidelines (§3.2): any phase can follow any other, in either state.
function PDEventStateMachine.SetPhase(record: EventRecord?, phase: string, actorUserId: number, now: number): (string?, string?)
	if record == nil or record.state == State.Inactive then
		return nil, "There is no PD event running."
	end
	if not PDPhases.IsValidPhase(phase) then
		return nil, `Unknown phase "{phase}". Use one of: {table.concat(PDPhases.Order, ", ")}.`
	end
	if record.phase == phase then
		return nil, `The event is already in the {phase} phase.`
	end
	local old = record.phase
	record.phase = phase
	table.insert(record.phaseLog, { phase = phase, at = now, by = actorUserId })
	return old, nil
end

-- `pendingDeathReports` is the number of unreviewed death reports for this event.
function PDEventStateMachine.End(
	record: EventRecord?,
	actorUserId: number,
	now: number,
	summary: string?,
	pendingDeathReports: number,
	force: boolean?
): (boolean, string?)
	if record == nil or record.state == State.Inactive then
		return false, "There is no PD event running."
	end
	if pendingDeathReports > 0 and not force then
		return false,
			`{pendingDeathReports} death report(s) from this event still need moderator review. Resolve them, or end with force.`
	end
	local window = record.activeWindows[#record.activeWindows]
	if window and window.to == nil then
		window.to = now
	end
	local pause = record.pauseLog[#record.pauseLog]
	if record.state == State.Paused and pause and pause.resumedAt == nil then
		pause.resumedAt = now
		pause.resumedBy = actorUserId
	end
	record.state = State.Inactive
	record.endedAt = now
	record.endedBy = actorUserId
	local text = trim(summary or "")
	if text ~= "" then
		record.summary = string.sub(text, 1, MAX_TEXT_LENGTH)
	end
	return true, nil
end

-- Called when a persisted event is loaded on server start. An event that was
-- Active when the server went down comes back Paused so nothing event-gated
-- happens until staff deliberately resume.
function PDEventStateMachine.Restore(record: EventRecord, now: number): boolean
	if record.state == State.Active then
		PDEventStateMachine.Pause(record, 0, now, "Server restarted during the event")
		return true
	end
	return false
end

function PDEventStateMachine.IsActive(record: EventRecord?): boolean
	return record ~= nil and record.state == State.Active
end

-- True if `timestamp` falls inside one of the event's Active windows.
function PDEventStateMachine.WasActiveAt(record: EventRecord?, timestamp: number): boolean
	if record == nil then
		return false
	end
	for _, window in record.activeWindows do
		if timestamp >= window.from and (window.to == nil or timestamp <= window.to) then
			return true
		end
	end
	return false
end

return PDEventStateMachine
