--!strict
-- Benchmark suite. Build with benchmark.project.json and press Run (F8):
--   rojo build benchmark.project.json --output benchmark.rbxl
-- Numbers are rough (Studio, single run) but comparable between changes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Networking)
local Signal = require(ReplicatedStorage.Networking.Shared.Signals.Signal)
local Dispatcher = require(ReplicatedStorage.Networking.Shared.Core.Dispatcher)
local Serializer = require(ReplicatedStorage.Networking.Shared.Serialization.Serializer)
local Compression = require(ReplicatedStorage.Networking.Shared.Compression.Compression)
local SchemaRegistry = require(ReplicatedStorage.Networking.Shared.Validation.SchemaRegistry)
local RateLimiter = require(ReplicatedStorage.Networking.Shared.Security.RateLimiter)

local V = Network.Validators

local function bench(name: string, iterations: number, fn: (i: number) -> ())
	-- warmup
	for index = 1, math.min(iterations // 10, 1000) do
		fn(index)
	end
	local startedAt = os.clock()
	for index = 1, iterations do
		fn(index)
	end
	local elapsed = os.clock() - startedAt
	local perSecond = iterations / elapsed
	print(string.format("%-40s %10d ops in %7.3fs  =%12.0f ops/s", name, iterations, elapsed, perSecond))
end

print("== Networking benchmarks ==")

-- Signal ------------------------------------------------------------------
do
	local signal = Signal.new() :: Signal.Signal<number>
	local sink = 0
	signal:Connect(function(value)
		sink += value
	end)
	bench("Signal:Fire (1 handler)", 200_000, function(index)
		signal:Fire(index)
	end)
	local multi = Signal.new() :: Signal.Signal<number>
	for _ = 1, 10 do
		multi:Connect(function(value)
			sink += value
		end)
	end
	bench("Signal:Fire (10 handlers)", 50_000, function(index)
		multi:Fire(index)
	end)
	local _ = sink
end

-- Dispatcher --------------------------------------------------------------
do
	local dispatcher = Dispatcher.new()
	local sink = 0
	dispatcher:On("Combat", "Damage", function(value)
		sink += value
	end)
	bench("Dispatcher route+fire", 200_000, function(index)
		dispatcher:Fire("Combat", "Damage", index)
	end)
	local _ = sink
end

-- Validation --------------------------------------------------------------
do
	local schema = { V.stringMaxLength(50), V.numberRange(0, 100), V.optional(V.integer) }
	bench("Schema check (3 args, pass)", 200_000, function(index)
		SchemaRegistry.check(schema, "sword", index % 100, 3)
	end)
	local shape = V.strictInterface({ ItemId = V.string, Amount = V.integerRange(1, 999) })
	local payload = { ItemId = "sword", Amount = 5 }
	bench("strictInterface (pass)", 200_000, function()
		shape(payload)
	end)
end

-- Rate limiter ------------------------------------------------------------
do
	local fakePlayer = { Name = "Bench", UserId = -1 } :: any
	bench("RateLimiter.check", 200_000, function()
		RateLimiter.check(fakePlayer, "Bench")
	end)
	RateLimiter.clearAll()
end

-- Serializer --------------------------------------------------------------
do
	local inventory = table.create(100)
	for index = 1, 100 do
		inventory[index] = { id = index, count = index % 50, rarity = 3, name = "item_" .. tostring(index % 10) }
	end
	local blob = Serializer.serialize(inventory)
	print(string.format("%-40s %d bytes", "Serialized 100-item inventory", buffer.len(blob)))
	bench("Serialize (100-item table)", 2_000, function()
		Serializer.serialize(inventory)
	end)
	bench("Deserialize (100-item table)", 2_000, function()
		Serializer.deserialize(blob)
	end)
end

-- Compression -------------------------------------------------------------
do
	local text = string.rep("BrainrotPetSimulator99 ", 400)
	local compressed = Compression.compress(text)
	print(string.format("%-40s %d -> %d bytes", "LZW on repetitive 9.2KB", #text, buffer.len(compressed)))
	bench("Compress (9.2KB repetitive)", 200, function()
		Compression.compress(text)
	end)
	bench("Decompress (same)", 500, function()
		Compression.decompress(compressed)
	end)
end

print("== done ==")
