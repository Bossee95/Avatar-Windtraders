--!strict
--[[
	KnockCore: pure rules for being downed, carried and executed (GDD §6.7).

	No Roblox APIs. KnockService owns one state per downed character and
	feeds it the clock.

	  Up --(health reaches HealthLimit)--> Down
	  Down --(timer runs out)--> Up (recovers)
	  Down --(V nearby)--> Carried --(V again / carrier hit)--> Down
	  Down --(B nearby)--> Gripped --(GripDuration passes)--> Executed
	                       Gripped --(B again / attacker hit)--> Down

	While Carried or Gripped the recovery timer is paused. Damage while Down
	extends the timer by ExtendOnDamage, never past Duration. After a carry or
	grip ends the character can't be picked up again for DropImmunity.
]]

export type Settings = {
	HealthLimit: number,
	Duration: number,
	ExtendOnDamage: number,
	GripDuration: number,
	DropImmunity: number,
	SearchRadius: number,
}

export type Mode = "Down" | "Carried" | "Gripped"

export type State = {
	mode: Mode,
	recoverAt: number, -- while Down
	remaining: number, -- saved timer while Carried or Gripped
	byUserId: number?, -- carrier or executioner
	gripDoneAt: number,
	immuneUntil: number,
}

local KnockCore = {}

function KnockCore.knock(settings: Settings, now: number): State
	return {
		mode = "Down",
		recoverAt = now + settings.Duration,
		remaining = 0,
		byUserId = nil,
		gripDoneAt = 0,
		immuneUntil = 0,
	}
end

function KnockCore.onDamaged(settings: Settings, state: State, now: number)
	if state.mode == "Down" then
		local left = math.max(0, state.recoverAt - now)
		state.recoverAt = now + math.min(settings.Duration, left + settings.ExtendOnDamage)
	end
end

function KnockCore.shouldRecover(state: State, now: number): boolean
	return state.mode == "Down" and now >= state.recoverAt
end

function KnockCore.timeLeft(state: State, now: number): number
	if state.mode == "Down" then
		return math.max(0, state.recoverAt - now)
	end
	return state.remaining
end

local function pause(state: State, now: number)
	state.remaining = math.max(0, state.recoverAt - now)
end

local function resume(settings: Settings, state: State, now: number)
	state.mode = "Down"
	state.recoverAt = now + state.remaining
	state.byUserId = nil
	state.immuneUntil = now + settings.DropImmunity
end

function KnockCore.startCarry(state: State, now: number, carrierUserId: number): (boolean, string?)
	if state.mode ~= "Down" then
		return false, "Busy"
	end
	if now < state.immuneUntil then
		return false, "Immune"
	end
	pause(state, now)
	state.mode = "Carried"
	state.byUserId = carrierUserId
	return true, nil
end

function KnockCore.stopCarry(settings: Settings, state: State, now: number)
	if state.mode == "Carried" then
		resume(settings, state, now)
	end
end

function KnockCore.startGrip(
	settings: Settings,
	state: State,
	now: number,
	attackerUserId: number
): (boolean, string?)
	if state.mode ~= "Down" then
		return false, "Busy"
	end
	if now < state.immuneUntil then
		return false, "Immune"
	end
	pause(state, now)
	state.mode = "Gripped"
	state.byUserId = attackerUserId
	state.gripDoneAt = now + settings.GripDuration
	return true, nil
end

function KnockCore.cancelGrip(settings: Settings, state: State, now: number)
	if state.mode == "Gripped" then
		resume(settings, state, now)
	end
end

function KnockCore.gripFinished(state: State, now: number): boolean
	return state.mode == "Gripped" and now >= state.gripDoneAt
end

-- Index of the nearest candidate within radius, or nil. Each candidate is
-- { distance, state? } where state is nil for characters that aren't down.
function KnockCore.pickTarget(
	settings: Settings,
	now: number,
	candidates: { { distance: number, state: State? } }
): number?
	local best, bestDistance = nil, math.huge
	for i, c in candidates do
		local s = c.state
		if
			s
			and s.mode == "Down"
			and now >= s.immuneUntil
			and c.distance <= settings.SearchRadius
			and c.distance < bestDistance
		then
			best, bestDistance = i, c.distance
		end
	end
	return best
end

return KnockCore
