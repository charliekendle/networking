--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Compression = require(ReplicatedStorage.Networking.Shared.Compression.Compression)
local Serializer = require(ReplicatedStorage.Networking.Shared.Serialization.Serializer)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function roundTrip(text: string): string
	return buffer.tostring(Compression.decompress(Compression.compress(text)))
end

spec["round-trips repetitive and plain data"] = function(expect)
	local repetitive = string.rep("the quick brown fox ", 200)
	expect.equal(roundTrip(repetitive), repetitive)
	expect.equal(roundTrip("short"), "short")
	expect.equal(roundTrip(""), "")
	expect.equal(roundTrip("aaaaaaaaaabbbbbbbbbb"), "aaaaaaaaaabbbbbbbbbb")
end

spec["repetitive data actually shrinks"] = function(expect)
	local text = string.rep("BrainrotPetSimulator", 500)
	local compressed = Compression.compress(text)
	expect.truthy(buffer.readu8(compressed, 0) == 1, "took the LZW path")
	expect.truthy(buffer.len(compressed) < #text / 3, `compressed {#text} -> {buffer.len(compressed)}`)
end

spec["incompressible data stores raw without growth"] = function(expect)
	local noise = table.create(512)
	math.randomseed(42)
	for index = 1, 512 do
		noise[index] = string.char(math.random(0, 255))
	end
	local text = table.concat(noise)
	local compressed = Compression.compress(text)
	expect.equal(buffer.readu8(compressed, 0), 0, "raw mode")
	expect.equal(buffer.len(compressed), #text + 1, "input + 1 header byte")
	expect.equal(roundTrip(text), text)
end

spec["buffer input round-trips"] = function(expect)
	local blob = Serializer.serialize({ rep = string.rep("x", 1000), n = 5 })
	local restored = Compression.decompress(Compression.compress(blob))
	local value = Serializer.deserialize(restored) :: any
	expect.equal(value.n, 5)
	expect.equal(#value.rep, 1000)
end

spec["corrupt input errors"] = function(expect)
	expect.errors(function()
		Compression.decompress(buffer.create(0))
	end)
	local badMode = buffer.create(3)
	buffer.writeu8(badMode, 0, 9)
	expect.errors(function()
		Compression.decompress(badMode)
	end)
	local badCode = buffer.create(3)
	buffer.writeu8(badCode, 0, 1)
	buffer.writeu16(badCode, 1, 60000) -- first code must be < 256
	expect.errors(function()
		Compression.decompress(badCode)
	end)
	local truncated = buffer.create(2)
	buffer.writeu8(truncated, 0, 1)
	expect.errors(function()
		Compression.decompress(truncated)
	end)
end

return spec
