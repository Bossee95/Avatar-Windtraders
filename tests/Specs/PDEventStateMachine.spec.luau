--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SM = require(ServerScriptService.Server.Services.PDEvent.PDEventStateMachine)
local PDPhases = require(ReplicatedStorage.Shared.PDEvent.PDPhases)

local State, Phase = PDPhases.State, PDPhases.Phase

return function(t)
	t.test("starts Active in Preparation by default", function()
		local rec, err = SM.Start(nil, "PD-1", "Opening night", 10, 1000)
		t.expect(err).toBeNil()
		local r = rec :: any
		t.expect(r.state).toBe(State.Active)
		t.expect(r.phase).toBe(Phase.Preparation)
		t.expect(#r.activeWindows).toBe(1)
		t.expect(SM.IsActive(r)).toBe(true)
	end)

	t.test("refuses a second start while one is running", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000)
		local second, err = SM.Start(rec, "PD-2", "B", 10, 1001)
		t.expect(second).toBeNil()
		t.expect(err).toBeTruthy()
	end)

	t.test("allows a new start after the previous event ended", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		SM.End(rec, 10, 1100, nil, 0)
		local second, err = SM.Start(rec, "PD-2", "B", 10, 1200)
		t.expect(err).toBeNil()
		t.expect((second :: any).id).toBe("PD-2")
	end)

	t.test("rejects empty names and unknown phases", function()
		local a, errA = SM.Start(nil, "PD-1", "   ", 10, 1000)
		t.expect(a).toBeNil()
		t.expect(errA).toBeTruthy()
		local b, errB = SM.Start(nil, "PD-1", "A", 10, 1000, "Siege")
		t.expect(b).toBeNil()
		t.expect(errB).toBeTruthy()
	end)

	t.test("pause and resume track active windows", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		t.expect((SM.Pause(rec, 11, 1100, "lag"))).toBe(true)
		t.expect(rec.state).toBe(State.Paused)
		t.expect(SM.IsActive(rec)).toBe(false)
		t.expect((SM.Pause(rec, 11, 1101))).toBe(false)
		t.expect((SM.Resume(rec, 11, 1200))).toBe(true)
		t.expect(rec.state).toBe(State.Active)
		t.expect(#rec.activeWindows).toBe(2)
		t.expect(rec.pauseLog[1].resumedAt).toBe(1200)
	end)

	t.test("WasActiveAt excludes paused time and time after the end", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		SM.Pause(rec, 11, 1100)
		SM.Resume(rec, 11, 1200)
		SM.End(rec, 10, 1300, nil, 0)
		t.expect(SM.WasActiveAt(rec, 1050)).toBe(true)
		t.expect(SM.WasActiveAt(rec, 1150)).toBe(false)
		t.expect(SM.WasActiveAt(rec, 1250)).toBe(true)
		t.expect(SM.WasActiveAt(rec, 1400)).toBe(false)
		t.expect(SM.WasActiveAt(rec, 999)).toBe(false)
	end)

	t.test("phases may change in any order", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		t.expect(SM.SetPhase(rec, Phase.Conflict, 10, 1010)).toBe(Phase.Preparation)
		t.expect(SM.SetPhase(rec, Phase.Development, 10, 1020)).toBe(Phase.Conflict)
		local same, err = SM.SetPhase(rec, Phase.Development, 10, 1030)
		t.expect(same).toBeNil()
		t.expect(err).toBeTruthy()
		t.expect(#rec.phaseLog).toBe(3)
	end)

	t.test("end is refused while death reports are pending unless forced", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		local ok, err = SM.End(rec, 10, 1100, "done", 2)
		t.expect(ok).toBe(false)
		t.expect(err).toBeTruthy()
		t.expect(rec.state).toBe(State.Active)
		t.expect((SM.End(rec, 10, 1100, "done", 2, true))).toBe(true)
		t.expect(rec.state).toBe(State.Inactive)
		t.expect(rec.summary).toBe("done")
		t.expect(rec.activeWindows[1].to).toBe(1100)
	end)

	t.test("ending a paused event closes the open pause", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		SM.Pause(rec, 11, 1100)
		SM.End(rec, 10, 1200, nil, 0)
		t.expect(rec.pauseLog[1].resumedAt).toBe(1200)
		t.expect(rec.activeWindows[1].to).toBe(1100)
	end)

	t.test("restore turns an Active event into Paused", function()
		local rec = SM.Start(nil, "PD-1", "A", 10, 1000) :: any
		t.expect(SM.Restore(rec, 5000)).toBe(true)
		t.expect(rec.state).toBe(State.Paused)
		t.expect(rec.pauseLog[1].by).toBe(0)
		local paused = SM.Start(nil, "PD-2", "B", 10, 1000) :: any
		SM.Pause(paused, 11, 1100)
		t.expect(SM.Restore(paused, 5000)).toBe(false)
	end)

	t.test("actions on no event fail cleanly", function()
		t.expect((SM.Pause(nil, 1, 1))).toBe(false)
		t.expect((SM.Resume(nil, 1, 1))).toBe(false)
		t.expect((SM.End(nil, 1, 1, nil, 0))).toBe(false)
		t.expect((SM.SetPhase(nil, Phase.Conflict, 1, 1))).toBeNil()
		t.expect(SM.WasActiveAt(nil, 1)).toBe(false)
	end)
end
