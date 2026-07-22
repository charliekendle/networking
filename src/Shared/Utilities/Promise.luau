--!strict
--[=[
	@class Promise

	Focused promise implementation backing Invoke (and exposed for reuse as
	`Network.Promise`). Supports chaining, error propagation, promise
	flattening, awaiting, and cancellation.

	```lua
	Shop:Invoke("GetCatalog", "Weapons")
		:AndThen(function(items)
			render(items)
		end)
		:Catch(function(reason)
			warn("Catalog failed:", reason)
		end)

	-- or synchronously inside a coroutine:
	local ok, items = Shop:Invoke("GetCatalog", "Weapons"):Await()
	```

	Semantics:
	- Handlers run asynchronously (`task.spawn`) — settling never re-enters
	  caller code on the same stack.
	- A handler returning a Promise flattens: the chain waits for it.
	- A handler that errors rejects the next promise in the chain.
	- `Cancel()` settles a pending promise as rejected with
	  `"Promise cancelled"` and runs any `onCancel` hooks (used by Invoke to
	  abandon the pending request).
]=]

local Promise = {}

export type Status = "Pending" | "Resolved" | "Rejected" | "Cancelled"

export type Promise = {
	GetStatus: (self: Promise) -> Status,
	AndThen: (self: Promise, onResolved: ((...any) -> ...any)?, onRejected: ((...any) -> ...any)?) -> Promise,
	Catch: (self: Promise, onRejected: (...any) -> ...any) -> Promise,
	Finally: (self: Promise, callback: () -> ()) -> Promise,
	Await: (self: Promise) -> (boolean, ...any),
	Expect: (self: Promise) -> ...any,
	Cancel: (self: Promise) -> (),
}

type Continuation = {
	onResolved: ((...any) -> ...any)?,
	onRejected: ((...any) -> ...any)?,
	resolve: (...any) -> (),
	reject: (...any) -> (),
}

type Internal = {
	_status: Status,
	_values: { n: number, [number]: any },
	_queue: { Continuation },
	_cancelHooks: { () -> () },
}

local PromiseClass = {}
PromiseClass.__index = PromiseClass

local function isPromise(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == PromiseClass
end

local function runContinuation(continuation: Continuation, status: Status, ...: any)
	local handler = if status == "Resolved" then continuation.onResolved else continuation.onRejected

	if handler == nil then
		-- Pass through unchanged.
		if status == "Resolved" then
			continuation.resolve(...)
		else
			continuation.reject(...)
		end
		return
	end

	local results = table.pack(pcall(handler, ...))
	if not results[1] then
		continuation.reject(results[2])
		return
	end

	local first = results[2]
	if isPromise(first) then
		-- Flatten: chain onto the returned promise.
		(first :: any):AndThen(continuation.resolve, continuation.reject)
	else
		continuation.resolve(table.unpack(results, 2, results.n))
	end
end

local function settle(self: any, status: Status, ...: any)
	if self._status ~= "Pending" then
		return
	end
	self._status = status
	self._values = table.pack(...)

	local queue: { Continuation } = self._queue
	self._queue = {}
	for _, continuation in queue do
		task.spawn(runContinuation, continuation, status, ...)
	end
end

--[=[
	Constructs a promise. The executor receives `(resolve, reject, onCancel)`;
	`onCancel(hook)` registers a cleanup hook and returns true if the promise
	was already cancelled. An executor that errors rejects the promise.
]=]
function Promise.new(
	executor: (resolve: (...any) -> (), reject: (...any) -> (), onCancel: (hook: () -> ()) -> boolean) -> ()
): Promise
	local self: Internal = setmetatable({
		_status = "Pending" :: Status,
		_values = table.pack(),
		_queue = {},
		_cancelHooks = {},
	}, PromiseClass) :: any

	local function resolve(...: any)
		settle(self, "Resolved", ...)
	end
	local function reject(...: any)
		settle(self, "Rejected", ...)
	end
	local function onCancel(hook: () -> ()): boolean
		if self._status == "Cancelled" then
			return true
		end
		table.insert(self._cancelHooks, hook)
		return false
	end

	local ok, err = pcall(executor :: (...any) -> ...any, resolve, reject, onCancel)
	if not ok then
		reject(err)
	end

	return (self :: any) :: Promise
end

--[=[ An immediately resolved promise. ]=]
function Promise.resolve(...: any): Promise
	local values = table.pack(...)
	return Promise.new(function(resolve)
		resolve(table.unpack(values, 1, values.n))
	end)
end

--[=[ An immediately rejected promise. ]=]
function Promise.reject(...: any): Promise
	local values = table.pack(...)
	return Promise.new(function(_resolve, reject)
		reject(table.unpack(values, 1, values.n))
	end)
end

--[=[ True if the value is a Promise from this module. ]=]
function Promise.is(value: unknown): boolean
	return isPromise(value)
end

function PromiseClass.GetStatus(self: any): Status
	return self._status
end

--[=[
	Chains handlers. Returns a new promise settling with the handler's
	return values (flattening returned promises); a handler that errors
	rejects the new promise.
]=]
function PromiseClass.AndThen(self: any, onResolved: ((...any) -> ...any)?, onRejected: ((...any) -> ...any)?): Promise
	return Promise.new(function(resolve, reject)
		local continuation: Continuation = {
			onResolved = onResolved,
			onRejected = onRejected,
			resolve = resolve,
			reject = reject,
		}
		if self._status == "Pending" then
			table.insert(self._queue, continuation)
		else
			task.spawn(runContinuation, continuation, self._status, table.unpack(self._values, 1, self._values.n))
		end
	end)
end

--[=[ `AndThen(nil, onRejected)`. Catches rejections (and cancellations). ]=]
function PromiseClass.Catch(self: any, onRejected: (...any) -> ...any): Promise
	return PromiseClass.AndThen(self, nil, onRejected)
end

--[=[
	Runs `callback` when the promise settles either way; values pass through
	untouched.
]=]
function PromiseClass.Finally(self: any, callback: () -> ()): Promise
	return PromiseClass.AndThen(self, function(...)
		callback()
		return ...
	end, function(...)
		callback()
		error(if select("#", ...) > 0 then (...) else "Promise rejected", 0)
	end)
end

--[=[
	Yields until settled. Returns `(true, ...values)` on resolve, or
	`(false, ...reason)` on reject/cancel.
]=]
function PromiseClass.Await(self: any): (boolean, ...any)
	if self._status == "Pending" then
		local thread = coroutine.running()
		table.insert(self._queue, {
			resolve = function(...)
				task.spawn(thread, true, ...)
			end,
			reject = function(...)
				task.spawn(thread, false, ...)
			end,
		} :: Continuation)
		return coroutine.yield()
	end
	return self._status == "Resolved", table.unpack(self._values, 1, self._values.n)
end

--[=[
	Yields until settled; returns values on resolve, errors on reject.
]=]
function PromiseClass.Expect(self: any): ...any
	local results = table.pack(PromiseClass.Await(self))
	if not results[1] then
		error(tostring(results[2]), 2)
	end
	return table.unpack(results, 2, results.n)
end

--[=[
	Cancels a pending promise: runs registered onCancel hooks, then settles
	as rejected with `"Promise cancelled"`. No-op if already settled.
]=]
function PromiseClass.Cancel(self: any)
	if self._status ~= "Pending" then
		return
	end
	for _, hook in self._cancelHooks :: { () -> () } do
		pcall(hook)
	end
	self._status = "Cancelled"
	self._values = table.pack("Promise cancelled")

	local queue: { Continuation } = self._queue
	self._queue = {}
	for _, continuation in queue do
		task.spawn(runContinuation, continuation, "Cancelled" :: Status, "Promise cancelled")
	end
end

return Promise
