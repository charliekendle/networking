--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SchemaRegistry = require(ReplicatedStorage.Networking.Shared.Validation.SchemaRegistry)
local V = require(ReplicatedStorage.Networking.Shared.Validation.Validators)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["set, get, clear"] = function(expect)
	SchemaRegistry.set("SpecChan", "Thing", { V.number })
	expect.truthy(SchemaRegistry.get("SpecChan", "Thing"))
	expect.falsy(SchemaRegistry.get("SpecChan", "Other"))
	expect.falsy(SchemaRegistry.get("OtherChan", "Thing"))
	SchemaRegistry.clear("SpecChan", "Thing")
	expect.falsy(SchemaRegistry.get("SpecChan", "Thing"))
end

spec["set rejects empty or invalid schemas"] = function(expect)
	expect.errors(function()
		SchemaRegistry.set("SpecChan", "Bad", {})
	end)
	expect.errors(function()
		SchemaRegistry.set("SpecChan", "Bad", { 5 :: any })
	end)
end

spec["check passes valid argument tuples"] = function(expect)
	local schema = { V.string, V.numberRange(0, 100) }
	expect.truthy(SchemaRegistry.check(schema, "sword", 50))
	local ok, reason = SchemaRegistry.check(schema, "sword", 999)
	expect.falsy(ok)
	expect.truthy(reason and string.find(reason, "arg #2"), "reason is positional")
end

spec["extra arguments are rejected"] = function(expect)
	local ok, reason = SchemaRegistry.check({ V.number }, 1, 2)
	expect.falsy(ok)
	expect.truthy(reason and string.find(reason, "too many"))
end

spec["trailing optionals express optional args"] = function(expect)
	local schema = { V.string, V.optional(V.integer) }
	expect.truthy(SchemaRegistry.check(schema, "sword"))
	expect.truthy(SchemaRegistry.check(schema, "sword", 3))
	expect.falsy(SchemaRegistry.check(schema, "sword", "three"))
	expect.falsy(SchemaRegistry.check(schema), "required arg missing fails")
end

spec["nil holes inside tuples are validated"] = function(expect)
	local schema = { V.number, V.number, V.number }
	local ok, reason = SchemaRegistry.check(schema, 1, nil, 3)
	expect.falsy(ok)
	expect.truthy(reason and string.find(reason, "arg #2"))
end

return spec
