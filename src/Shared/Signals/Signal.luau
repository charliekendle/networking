--!strict
--[=[
	@class Signal

	Strict-typed signal implementation used throughout the package
	(config changes, debug events, security hooks, internal listener registry).

	Design:
	- Singly-linked handler list: O(1) connect, O(1) fire per handler, no array churn.
	- Recycled runner thread: firing a handler that never yields reuses one
	  coroutine instead of allocating a new thread per dispatch, which keeps
	  GC pressure flat under thousands of packets/sec.
	- Handlers run via task.spawn semantics: errors in one handler never
	  break the dispatch loop or other handlers.

	```lua
	local signal = Signal.new() :: Signal.Signal<number, string>
	local connection = signal:Connect(function(id, name) end)
	signal:Fire(1, "hello")
	connection:Disconnect()
	```
]=]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

type Handler = {
	_callback: (...any) -> (),
	_next: Handler?,
	Connected: boolean,
	Disconnect: (self: Handler) -> (),
}

type SignalInternal = {
	_head: Handler?,
	_destroyed: boolean,
}

-- One idle runner thread is kept warm. When a handler yields, the runner is
-- "stolen" for the duration and a fresh one is created on the next dispatch
-- that needs it. Net effect: zero thread allocation for non-yielding handlers.
local idleRunner: thread? = nil

local function callHandler(callback: (...any) -> (), ...: any)
	local runner = idleRunner :: thread
	idleRunner = nil
	callback(...)
	idleRunner = runner
end

local function runnerLoop(...: any)
	callHandler(...)
	while true do
		callHandler(coroutine.yield())
	end
end

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

function ConnectionClass.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal: SignalInternal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local previous = signal._head
		while previous and previous._next ~= self do
			previous = previous._next
		end
		if previous then
			previous._next = self._next
		end
	end
end

local SignalClass = {}
SignalClass.__index = SignalClass

function SignalClass.Connect(self: any, callback: (...any) -> ()): Connection
	assert(type(callback) == "function", "Signal:Connect expects a function")
	assert(not self._destroyed, "Cannot connect to a destroyed Signal")

	local handler = setmetatable({
		_signal = self,
		_callback = callback,
		_next = self._head,
		Connected = true,
	}, ConnectionClass)

	self._head = handler
	return (handler :: any) :: Connection
end

function SignalClass.Once(self: any, callback: (...any) -> ()): Connection
	local connection: Connection
	connection = SignalClass.Connect(self, function(...)
		if connection.Connected then
			connection:Disconnect()
		end
		callback(...)
	end)
	return connection
end

function SignalClass.Wait(self: any): ...any
	local waitingThread = coroutine.running()
	local connection: Connection
	connection = SignalClass.Connect(self, function(...)
		connection:Disconnect()
		task.spawn(waitingThread, ...)
	end)
	return coroutine.yield()
end

function SignalClass.Fire(self: any, ...: any)
	local handler: Handler? = self._head
	while handler do
		if handler.Connected then
			if idleRunner == nil then
				idleRunner = coroutine.create(runnerLoop)
			end
			task.spawn(idleRunner :: thread, handler._callback, ...)
		end
		handler = handler._next
	end
end

function SignalClass.DisconnectAll(self: any)
	local handler: Handler? = self._head
	while handler do
		handler.Connected = false
		handler = handler._next
	end
	self._head = nil
end

function SignalClass.Destroy(self: any)
	SignalClass.DisconnectAll(self)
	self._destroyed = true
end

local Signal = {}

--[=[
	Creates a new Signal. Annotate the generic at the call site:

	```lua
	local damaged = Signal.new() :: Signal.Signal<Player, number>
	```
]=]
function Signal.new<T...>(): Signal<T...>
	local self: SignalInternal = setmetatable({
		_head = nil,
		_destroyed = false,
	}, SignalClass) :: any
	return (self :: any) :: Signal<T...>
end

--[=[
	Returns true if the value is a Signal created by this module.
]=]
function Signal.is(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == SignalClass
end

return Signal
