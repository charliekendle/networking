--!strict
--[=[
	@class TableUtil

	Small table helpers shared across the package. Kept deliberately tiny —
	no general-purpose kitchen sink, only what internal modules need.
]=]

local TableUtil = {}

type AnyTable = { [any]: any }

--[=[
	Recursively copies a table. Non-table values are copied by reference/value
	as appropriate. Does not handle cyclic tables (internal config data never cycles).
]=]
function TableUtil.deepCopy<T>(source: T & AnyTable): T
	local copy: AnyTable = {}
	for key, value in source :: AnyTable do
		if type(value) == "table" then
			copy[key] = TableUtil.deepCopy(value)
		else
			copy[key] = value
		end
	end
	return (copy :: any) :: T
end

--[=[
	Recursively merges `patch` into `target` (mutates and returns `target`).
	Table values merge; everything else overwrites.
]=]
function TableUtil.deepMerge(target: AnyTable, patch: AnyTable): AnyTable
	for key, value in patch do
		if type(value) == "table" and type(target[key]) == "table" then
			TableUtil.deepMerge(target[key], value)
		else
			target[key] = value
		end
	end
	return target
end

--[=[
	Returns a recursively frozen deep copy of `source`.
]=]
function TableUtil.deepFreeze<T>(source: T & AnyTable): T
	local copy: AnyTable = TableUtil.deepCopy(source)
	local function freeze(tbl: AnyTable)
		for _, value in tbl do
			if type(value) == "table" then
				freeze(value)
			end
		end
		table.freeze(tbl)
	end
	freeze(copy)
	return (copy :: any) :: T
end

--[=[
	Shallow count of entries in a dictionary.
]=]
function TableUtil.count(tbl: AnyTable): number
	local total = 0
	for _ in tbl do
		total += 1
	end
	return total
end

return TableUtil
