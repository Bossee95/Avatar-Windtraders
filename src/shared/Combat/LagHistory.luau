--!strict
--[[
	LagHistory: a short ring buffer of timestamped positions, for lag
	compensation (CombatSettings.LagCompensation). Pure: positions are any
	value that supports a + (b - a) * t (Vector3 in the game, numbers in specs).

	  local h = LagHistory.new(32)
	  LagHistory.push(h, time, position)
	  LagHistory.at(h, time) -> position? (interpolated; nil outside the window)
]]

export type History<T> = {
	capacity: number,
	times: { number },
	values: { T },
	head: number, -- index of the newest sample
	count: number,
}

local LagHistory = {}

function LagHistory.new<T>(capacity: number): History<T>
	return { capacity = capacity, times = {}, values = {}, head = 0, count = 0 }
end

function LagHistory.push<T>(h: History<T>, time: number, value: T)
	h.head = h.head % h.capacity + 1
	h.times[h.head] = time
	h.values[h.head] = value
	h.count = math.min(h.count + 1, h.capacity)
end

-- Sample i steps back from the newest (0 = newest).
local function index<T>(h: History<T>, back: number): number
	return (h.head - 1 - back) % h.capacity + 1
end

function LagHistory.at<T>(h: History<T>, time: number): T?
	if h.count == 0 then
		return nil
	end
	local newest = index(h, 0)
	if time >= h.times[newest] then
		return h.values[newest]
	end
	for back = 1, h.count - 1 do
		local older = index(h, back)
		local newer = index(h, back - 1)
		local t0, t1 = h.times[older], h.times[newer]
		if time >= t0 then
			local span = t1 - t0
			local alpha = if span > 0 then (time - t0) / span else 0
			local a: any, b: any = h.values[older], h.values[newer]
			return a + (b - a) * alpha
		end
	end
	return nil
end

return LagHistory
