--!strict
--[[
	Per-owner action cooldowns. Pure: the clock is injected so it can be
	tested.
]]

local Cooldowns = {}
Cooldowns.__index = Cooldowns

export type Cooldowns = typeof(setmetatable(
	{} :: {
		_clock: () -> number,
		_ready: { [any]: { [string]: number } },
	},
	Cooldowns
))

function Cooldowns.new(clock: (() -> number)?): Cooldowns
	return setmetatable({ _clock = clock or os.clock, _ready = {} }, Cooldowns)
end

-- Returns whether the action is off cooldown, and the seconds left if not.
function Cooldowns.isReady(self: Cooldowns, owner: any, actionId: string): (boolean, number)
	local byAction = self._ready[owner]
	local readyAt = byAction and byAction[actionId]
	if not readyAt then
		return true, 0
	end
	local left = readyAt - self._clock()
	if left <= 0 then
		return true, 0
	end
	return false, left
end

function Cooldowns.start(self: Cooldowns, owner: any, actionId: string, duration: number)
	if duration <= 0 then
		return
	end
	local byAction = self._ready[owner]
	if not byAction then
		byAction = {}
		self._ready[owner] = byAction
	end
	byAction[actionId] = self._clock() + duration
end

-- Seconds left for every action still cooling down, for the client HUD.
function Cooldowns.snapshot(self: Cooldowns, owner: any): { [string]: number }
	local out = {}
	local now = self._clock()
	for actionId, readyAt in self._ready[owner] or {} do
		if readyAt > now then
			out[actionId] = readyAt - now
		end
	end
	return out
end

function Cooldowns.clear(self: Cooldowns, owner: any)
	self._ready[owner] = nil
end

return Cooldowns
