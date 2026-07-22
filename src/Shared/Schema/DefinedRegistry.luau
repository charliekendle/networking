--!strict
--[=[
	@class DefinedRegistry

	Maps `(channel, event)` to the Schema codec registered via
	`channel:Define`. Context-local. The transports consult this on receive:
	a defined event's payload must be exactly one buffer that decodes
	cleanly under the codec — anything else is a validation violation.
]=]

local Schema = require(script.Parent.Schema)

local DefinedRegistry = {}

local defined: { [string]: { [string]: Schema.Codec<any> } } = {}

function DefinedRegistry.set(channelName: string, eventName: string, codec: Schema.Codec<any>)
	assert(Schema.is(codec), "Define expects a Schema codec")
	local events = defined[channelName]
	if events == nil then
		events = {}
		defined[channelName] = events
	end
	assert(events[eventName] == nil, `Event "{eventName}" is already defined on channel "{channelName}"`)
	events[eventName] = codec
end

function DefinedRegistry.get(channelName: string, eventName: string): Schema.Codec<any>?
	local events = defined[channelName]
	return if events then events[eventName] else nil
end

--[=[ Test-only. ]=]
function DefinedRegistry.clearAll()
	table.clear(defined)
end

return DefinedRegistry
