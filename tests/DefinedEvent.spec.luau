--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Networking)
local DefinedRegistry = require(ReplicatedStorage.Networking.Shared.Schema.DefinedRegistry)
local TestKit = require(script.Parent.TestKit)

local S = Network.Schema

local spec: TestKit.Spec = {}

spec["define registers the codec and returns a working handle"] = function(expect)
	local channel = Network.Channel("SpecDefined")
	local def = channel:Define("Thing", S.struct({ Power = S.int(0, 100) }))
	expect.equal(def.Name, "Thing")
	expect.equal(def.Channel, "SpecDefined")
	expect.truthy(DefinedRegistry.get("SpecDefined", "Thing"))

	local connection = def:On(function() end)
	expect.truthy(connection.Connected)
	def:Off()
	expect.falsy(connection.Connected)
end

spec["duplicate definitions error"] = function(expect)
	local channel = Network.Channel("SpecDefined")
	channel:Define("Once", S.u8)
	expect.errors(function()
		channel:Define("Once", S.u8)
	end)
end

spec["define rejects non-codecs and reserved names"] = function(expect)
	local channel = Network.Channel("SpecDefined")
	expect.errors(function()
		channel:Define("Bad", (function() end) :: any) -- a Validator is not a codec
	end)
	expect.errors(function()
		channel:Define("__reserved", S.u8)
	end)
end

spec["typed fires encode and reject out-of-schema values at the send site"] = function(expect)
	local channel = Network.Channel("SpecDefined")
	local def = channel:Define("Broadcast", S.struct({ Power = S.int(0, 100) }))
	def:FireAll({ Power = 50 }) -- zero players in Run mode; must not error
	expect.errors(function()
		def:FireAll({ Power = 999 })
	end)
	expect.errors(function()
		def:FireAll({ Power = 50, Extra = true } :: any)
	end)
end

return spec
