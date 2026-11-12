--!strict
--[[
	MockDataStore: an in-memory stand-in for a GlobalDataStore.

	Used in Studio when API access is disabled, and by tests. Values are
	deep-copied in and out so callers can't accidentally share tables with the
	"stored" copy, the same as a real DataStore. Supports GetAsync, SetAsync,
	UpdateAsync and RemoveAsync.

	Test helpers:
		mock:FailNext(count, message?)  -- the next `count` requests error
		mock:Peek(key)                  -- raw stored value (copy)
]]

local Table = require(game:GetService("ReplicatedStorage").Shared.Util.Table)

local MockDataStore = {}
MockDataStore.__index = MockDataStore

function MockDataStore.new()
	return setmetatable({
		_values = {} :: { [string]: any },
		_failCount = 0,
		_failMessage = "MockDataStore: simulated failure",
	}, MockDataStore)
end

function MockDataStore:FailNext(count: number, message: string?)
	self._failCount = count
	if message then
		self._failMessage = message
	end
end

function MockDataStore:_maybeFail()
	if self._failCount > 0 then
		self._failCount -= 1
		error(self._failMessage, 0)
	end
end

function MockDataStore:Peek(key: string): any
	return Table.deepCopy(self._values[key])
end

function MockDataStore:GetAsync(key: string): any
	self:_maybeFail()
	return Table.deepCopy(self._values[key])
end

function MockDataStore:SetAsync(key: string, value: any)
	self:_maybeFail()
	self._values[key] = Table.deepCopy(value)
end

function MockDataStore:UpdateAsync(key: string, transform: (any, any) -> any): any
	self:_maybeFail()
	local result = transform(Table.deepCopy(self._values[key]), nil)
	if result == nil then
		-- Returning nil cancels the update, like the real API.
		return Table.deepCopy(self._values[key])
	end
	self._values[key] = Table.deepCopy(result)
	return Table.deepCopy(result)
end

function MockDataStore:RemoveAsync(key: string): any
	self:_maybeFail()
	local old = self._values[key]
	self._values[key] = nil
	return old
end

return MockDataStore
