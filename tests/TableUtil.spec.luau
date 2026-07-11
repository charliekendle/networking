--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Networking.Shared.Utilities.TableUtil)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["deepCopy produces an independent copy"] = function(expect)
	local original = { a = 1, nested = { b = 2 } }
	local copy = TableUtil.deepCopy(original)
	copy.nested.b = 99
	expect.equal(original.nested.b, 2)
	expect.equal(copy.a, 1)
end

spec["deepMerge overwrites scalars and merges tables"] = function(expect)
	local target = { a = 1, nested = { x = 1, y = 2 } }
	TableUtil.deepMerge(target, { a = 5, nested = { y = 9 } })
	expect.equal(target.a, 5)
	expect.equal(target.nested.x, 1)
	expect.equal(target.nested.y, 9)
end

spec["deepFreeze freezes recursively without touching source"] = function(expect)
	local source = { nested = { value = 1 } }
	local frozen = TableUtil.deepFreeze(source)
	expect.errors(function()
		(frozen.nested :: any).value = 2
	end)
	source.nested.value = 3
	expect.equal(source.nested.value, 3, "source stays mutable")
end

spec["count counts dictionary entries"] = function(expect)
	expect.equal(TableUtil.count({}), 0)
	expect.equal(TableUtil.count({ a = 1, b = 2, c = 3 }), 3)
end

return spec
