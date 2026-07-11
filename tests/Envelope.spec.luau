--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Envelope = require(ReplicatedStorage.Networking.Shared.Core.Envelope)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["accepts normal event names"] = function(expect)
	expect.truthy(Envelope.isValidEventName("Damage"))
	expect.truthy(Envelope.isValidEventName("a"))
	expect.truthy(Envelope.isValidEventName(string.rep("x", 100)))
end

spec["rejects non-strings and empty"] = function(expect)
	expect.falsy(Envelope.isValidEventName(nil))
	expect.falsy(Envelope.isValidEventName(5))
	expect.falsy(Envelope.isValidEventName({}))
	expect.falsy(Envelope.isValidEventName(""))
end

spec["rejects oversized and reserved names"] = function(expect)
	expect.falsy(Envelope.isValidEventName(string.rep("x", 101)))
	expect.falsy(Envelope.isValidEventName("__internal"))
end

spec["assertEventName errors on bad local input"] = function(expect)
	expect.errors(function()
		Envelope.assertEventName("")
	end)
	expect.errors(function()
		Envelope.assertEventName("__reserved")
	end)
	expect.equal(Envelope.assertEventName("Fine"), "Fine")
end

spec["assertChannelName rejects instance-unsafe characters"] = function(expect)
	expect.errors(function()
		Envelope.assertChannelName("bad/name")
	end)
	expect.errors(function()
		Envelope.assertChannelName("bad.name")
	end)
	expect.equal(Envelope.assertChannelName("Combat"), "Combat")
end

return spec
