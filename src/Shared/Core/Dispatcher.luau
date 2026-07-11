--!strict
--[=[
	@class Dispatcher

	Routing table mapping `(channel, event)` to a Signal of listeners.
	Both transports own one instance; it is pure bookkeeping with no
	knowledge of remotes, players, or contexts — which is what makes it
	fully unit-testable on its own.
]=]

local Signal = require(script.Parent.Parent.Signals.Signal)

type AnySignal = Signal.Signal<...any>
export type Connection = Signal.Connection

export type Dispatcher = {
	On: (self: Dispatcher, channel: string, event: string, callback: (...any) -> ()) -> Connection,
	Once: (self: Dispatcher, channel: string, event: string, callback: (...any) -> ()) -> Connection,
	Fire: (self: Dispatcher, channel: string, event: string, ...any) -> (),
	Off: (self: Dispatcher, channel: string, event: string) -> (),
	HasListeners: (self: Dispatcher, channel: string, event: string) -> boolean,
}

type DispatcherInternal = {
	_channels: { [string]: { [string]: AnySignal } },
}

local DispatcherClass = {}
DispatcherClass.__index = DispatcherClass

local function getSignal(self: DispatcherInternal, channel: string, event: string, create: boolean): AnySignal?
	local events = self._channels[channel]
	if events == nil then
		if not create then
			return nil
		end
		events = {}
		self._channels[channel] = events
	end

	local signal = events[event]
	if signal == nil and create then
		signal = Signal.new() :: AnySignal
		events[event] = signal
	end
	return signal
end

--[=[
	Registers a listener. Returns a Connection.
]=]
function DispatcherClass.On(self: any, channel: string, event: string, callback: (...any) -> ()): Connection
	local signal = getSignal(self, channel, event, true) :: AnySignal
	return signal:Connect(callback)
end

--[=[
	Registers a listener that disconnects itself after the first dispatch.
]=]
function DispatcherClass.Once(self: any, channel: string, event: string, callback: (...any) -> ()): Connection
	local signal = getSignal(self, channel, event, true) :: AnySignal
	return signal:Once(callback)
end

--[=[
	Dispatches to every listener of `(channel, event)`. No-op if none.
]=]
function DispatcherClass.Fire(self: any, channel: string, event: string, ...: any)
	local signal = getSignal(self, channel, event, false)
	if signal then
		signal:Fire(...)
	end
end

--[=[
	Disconnects every listener of `(channel, event)`.
]=]
function DispatcherClass.Off(self: any, channel: string, event: string)
	local signal = getSignal(self, channel, event, false)
	if signal then
		signal:DisconnectAll()
	end
end

--[=[
	True if at least one connected listener exists for `(channel, event)`.
	The debug/statistics layer uses this; user code rarely needs it.
]=]
function DispatcherClass.HasListeners(self: any, channel: string, event: string): boolean
	local signal = getSignal(self, channel, event, false)
	if signal == nil then
		return false
	end
	-- Peek the handler list without exposing Signal internals publicly.
	local head = (signal :: any)._head
	while head do
		if head.Connected then
			return true
		end
		head = head._next
	end
	return false
end

local Dispatcher = {}

function Dispatcher.new(): Dispatcher
	local self: DispatcherInternal = setmetatable({
		_channels = {},
	}, DispatcherClass) :: any
	return (self :: any) :: Dispatcher
end

return Dispatcher
