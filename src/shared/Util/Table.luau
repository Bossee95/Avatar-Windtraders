--!strict
--[[
	Table helpers used by the data layer.
]]

local Table = {}

-- Recursive copy. Metatables are not copied. Cycles are not supported.
function Table.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value :: any do
		copy[Table.deepCopy(k)] = Table.deepCopy(v)
	end
	return copy :: any
end

-- Recursively freezes a table so any write errors. Returns the same table.
function Table.deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, v in value :: any do
			Table.deepFreeze(v)
		end
		table.freeze(value :: any)
	end
	return value
end

-- Fills keys missing from `target` with deep copies from `template`,
-- recursing into nested tables that exist in both. Existing values win.
-- Array-like templates are not merged into (an empty default list stays the
-- player's list). Returns `target`.
function Table.reconcile(target: { [any]: any }, template: { [any]: any }): { [any]: any }
	for k, v in template do
		local current = target[k]
		if current == nil then
			target[k] = Table.deepCopy(v)
		elseif type(current) == "table" and type(v) == "table" and next(v) ~= nil and #v == 0 then
			Table.reconcile(current, v)
		end
	end
	return target
end

-- Structural equality, for tests.
function Table.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not Table.deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function Table.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

return Table
