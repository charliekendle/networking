--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Networking.Shared.Utilities.Promise)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["resolves through andThen chains"] = function(expect)
	local got
	Promise.resolve(5)
		:AndThen(function(value)
			return value * 2
		end)
		:AndThen(function(value)
			got = value
		end)
	task.wait()
	expect.equal(got, 10)
end

spec["rejections skip to catch"] = function(expect)
	local caught
	local skipped = false
	Promise.reject("boom")
		:AndThen(function()
			skipped = true
		end)
		:Catch(function(reason)
			caught = reason
		end)
	task.wait()
	expect.equal(caught, "boom")
	expect.falsy(skipped)
end

spec["handler errors reject the chain"] = function(expect)
	local caught
	Promise.resolve()
		:AndThen(function()
			error("handler blew up")
		end)
		:Catch(function(reason)
			caught = tostring(reason)
		end)
	task.wait()
	expect.truthy(caught and string.find(caught, "handler blew up"))
end

spec["returned promises flatten"] = function(expect)
	local got
	Promise.resolve(1)
		:AndThen(function(value)
			return Promise.new(function(resolve)
				task.delay(0.05, resolve, value + 100)
			end)
		end)
		:AndThen(function(value)
			got = value
		end)
	task.wait(0.15)
	expect.equal(got, 101)
end

spec["await yields until settled"] = function(expect)
	local promise = Promise.new(function(resolve)
		task.delay(0.05, resolve, "late", 2)
	end)
	local ok, first, second = promise:Await()
	expect.truthy(ok)
	expect.equal(first, "late")
	expect.equal(second, 2)

	local failed = Promise.reject("nope")
	local ok2, reason = failed:Await()
	expect.falsy(ok2)
	expect.equal(reason, "nope")
end

spec["expect errors on rejection"] = function(expect)
	expect.equal(Promise.resolve(7):Expect(), 7)
	expect.errors(function()
		Promise.reject("bad"):Expect()
	end)
end

spec["cancel runs hooks and rejects downstream"] = function(expect)
	local hookRan = false
	local caught
	local promise = Promise.new(function(_resolve, _reject, onCancel)
		onCancel(function()
			hookRan = true
		end)
	end)
	promise:Catch(function(reason)
		caught = reason
	end)
	promise:Cancel()
	task.wait()
	expect.truthy(hookRan)
	expect.equal(caught, "Promise cancelled")
	expect.equal(promise:GetStatus(), "Cancelled")
	promise:Cancel() -- second cancel is a no-op
end

spec["finally runs on both paths"] = function(expect)
	local runs = 0
	Promise.resolve():Finally(function()
		runs += 1
	end)
	Promise.reject("x"):Finally(function()
		runs += 1
	end):Catch(function() end)
	task.wait()
	expect.equal(runs, 2)
end

spec["settling twice is a no-op"] = function(expect)
	local got
	Promise.new(function(resolve, reject)
		resolve("first")
		reject("second")
		resolve("third")
	end):AndThen(function(value)
		got = value
	end)
	task.wait()
	expect.equal(got, "first")
end

spec["is() identifies promises"] = function(expect)
	expect.truthy(Promise.is(Promise.resolve()))
	expect.falsy(Promise.is({}))
	expect.falsy(Promise.is(nil))
end

return spec
