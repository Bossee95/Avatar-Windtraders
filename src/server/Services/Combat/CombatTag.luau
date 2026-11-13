--!strict
--[[
	Combat tag bookkeeping (GDD §5.3, §19.5). Pure: the clock is injected so
	it can be tested. CombatService owns one instance keyed by player.
]]

local CombatTag = {}
CombatTag.__index = CombatTag

export type CombatTag = typeof(setmetatable(
	{} :: {
		_duration: number,
		_clock: () -> number,
		_until: { [any]: number },
	},
	CombatTag
))

function CombatTag.new(duration: number, clock: (() -> number)?): CombatTag
	return setmetatable({
		_duration = duration,
		_clock = clock or os.clock,
		_until = {},
	}, CombatTag)
end

-- Tags (or refreshes) a key. Returns true if it was not tagged before.
function CombatTag.tag(self: CombatTag, key: any): boolean
	local wasTagged = self:isTagged(key)
	self._until[key] = self._clock() + self._duration
	return not wasTagged
end

function CombatTag.isTagged(self: CombatTag, key: any): boolean
	local t = self._until[key]
	return t ~= nil and self._clock() < t
end

function CombatTag.remaining(self: CombatTag, key: any): number
	local t = self._until[key]
	if not t then
		return 0
	end
	return math.max(0, t - self._clock())
end

-- Removes a key. Returns true if it was tagged.
function CombatTag.clear(self: CombatTag, key: any): boolean
	local wasTagged = self:isTagged(key)
	self._until[key] = nil
	return wasTagged
end

-- Removes expired keys and returns them, so the caller can announce that
-- they left combat.
function CombatTag.collectExpired(self: CombatTag): { any }
	local now = self._clock()
	local expired = {}
	for key, t in self._until do
		if now >= t then
			table.insert(expired, key)
		end
	end
	for _, key in expired do
		self._until[key] = nil
	end
	return expired
end

return CombatTag
