--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Networking.Shared.Signals.Signal)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["fires connected handlers with arguments"] = function(expect)
	local signal = Signal.new() :: Signal.Signal<number, string>
	local gotA, gotB
	signal:Connect(function(a, b)
		gotA, gotB = a, b
	end)
	signal:Fire(5, "hi")
	task.wait()
	expect.equal(gotA, 5)
	expect.equal(gotB, "hi")
end

spec["disconnect stops delivery"] = function(expect)
	local signal = Signal.new() :: Signal.Signal<>
	local count = 0
	local connection = signal:Connect(function()
		count += 1
	end)
	signal:Fire()
	task.wait()
	connection:Disconnect()
	expect.falsy(connection.Connected, "Connected flag cleared")
	signal:Fire()
	task.wait()
	expect.equal(count, 1)
end

spec["once only fires a single time"] = function(expect)
	local signal = Signal.new() :: Signal.Signal<>
	local count = 0
	signal:Once(function()
		count += 1
	end)
	signal:Fire()
	signal:Fire()
	task.wait()
	expect.equal(count, 1)
end

spec["wait resumes with fired values"] = function(expect)
	local signal = Signal.new() :: Signal.Signal<number>
	local got
	local thread = task.spawn(function()
		got = signal:Wait()
	end)
	task.wait()
	signal:Fire(42)
	task.wait()
	expect.equal(got, 42)
	expect.equal(coroutine.status(thread), "dead")
end

spec["handler errors do not break other handlers"] = function(expect)
	local signal = Signal.new() :: Signal.Signal<>
	local reached = false
	signal:Connect(function()
		error("intentional test error")
	end)
	signal:Connect(function()
		reached = true
	end)
	signal:Fire()
	task.wait()
	expect.truthy(reached, "second handler still ran")
end

spec["disconnectAll clears every handler"] = function(expect)
	local signal = Signal.new() :: Signal.Signal<>
	local count = 0
	for _ = 1, 3 do
		signal:Connect(function()
			count += 1
		end)
	end
	signal:DisconnectAll()
	signal:Fire()
	task.wait()
	expect.equal(count, 0)
end

spec["is() identifies signals"] = function(expect)
	expect.truthy(Signal.is(Signal.new()))
	expect.falsy(Signal.is({}))
	expect.falsy(Signal.is(5))
end

return spec
