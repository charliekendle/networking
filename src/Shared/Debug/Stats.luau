--!strict
--[=[
	@class Stats

	Runtime statistics and debug instrumentation. Counter updates are plain
	integer bumps and always on; the packet log only records while
	`Config.DebugMode` is true.

	```lua
	Network.Configure({ DebugMode = true })

	local stats = Network.GetStats()
	print(stats.Sent, stats.Received, stats.Dropped)
	print(stats.PerChannel.Combat.Received)
	print(stats.AverageInvokeRtt)

	for _, entry in Network.GetPacketLog() do
		print(entry.Direction, entry.Channel, entry.Event, entry.ArgCount)
	end
	```
]=]

local Config = require(script.Parent.Parent.Config)

local PACKET_LOG_CAPACITY = 128
local RTT_SAMPLE_CAPACITY = 64

export type ChannelStats = {
	Sent: number,
	Received: number,
	Dropped: number,
}

export type StatsSnapshot = {
	Sent: number,
	Received: number,
	Dropped: number,
	PerChannel: { [string]: ChannelStats },
	AverageInvokeRtt: number?, -- seconds, rolling window of recent invokes
	PacketLogEnabled: boolean,
}

export type PacketLogEntry = {
	Time: number, -- os.clock()
	Direction: "Send" | "Receive",
	Channel: string,
	Event: string,
	ArgCount: number,
	Player: string?, -- sender/recipient name where known
}

local Stats = {}

local totalSent = 0
local totalReceived = 0
local totalDropped = 0
local perChannel: { [string]: ChannelStats } = {}

local packetLog: { PacketLogEntry } = {}
local packetLogIndex = 0
local packetLogCount = 0

local rttSamples: { number } = {}
local rttIndex = 0
local rttCount = 0

local function channelStats(channelName: string): ChannelStats
	local stats = perChannel[channelName]
	if stats == nil then
		stats = { Sent = 0, Received = 0, Dropped = 0 }
		perChannel[channelName] = stats
	end
	return stats
end

local function logPacket(direction: "Send" | "Receive", channelName: string, eventName: string, argCount: number, playerName: string?)
	if not Config.Get().DebugMode then
		return
	end
	packetLogIndex = packetLogIndex % PACKET_LOG_CAPACITY + 1
	packetLog[packetLogIndex] = {
		Time = os.clock(),
		Direction = direction,
		Channel = channelName,
		Event = eventName,
		ArgCount = argCount,
		Player = playerName,
	}
	packetLogCount = math.min(packetLogCount + 1, PACKET_LOG_CAPACITY)
end

--[=[ Records an outbound packet. Internal — transports call this. ]=]
function Stats.countSend(channelName: string, eventName: string, argCount: number, playerName: string?)
	totalSent += 1
	channelStats(channelName).Sent += 1
	logPacket("Send", channelName, eventName, argCount, playerName)
end

--[=[ Records an inbound packet that reached dispatch. Internal. ]=]
function Stats.countReceive(channelName: string, eventName: string, argCount: number, playerName: string?)
	totalReceived += 1
	channelStats(channelName).Received += 1
	logPacket("Receive", channelName, eventName, argCount, playerName)
end

--[=[ Records an inbound packet dropped by any pipeline stage. Internal. ]=]
function Stats.countDrop(channelName: string)
	totalDropped += 1
	channelStats(channelName).Dropped += 1
end

--[=[ Records one invoke round-trip time in seconds. Internal. ]=]
function Stats.recordRtt(seconds: number)
	rttIndex = rttIndex % RTT_SAMPLE_CAPACITY + 1
	rttSamples[rttIndex] = seconds
	rttCount = math.min(rttCount + 1, RTT_SAMPLE_CAPACITY)
end

--[=[
	Returns a snapshot of counters (copies — safe to hold).
]=]
function Stats.getSnapshot(): StatsSnapshot
	local channels: { [string]: ChannelStats } = {}
	for name, stats in perChannel do
		channels[name] = { Sent = stats.Sent, Received = stats.Received, Dropped = stats.Dropped }
	end

	local averageRtt: number? = nil
	if rttCount > 0 then
		local sum = 0
		for index = 1, rttCount do
			sum += rttSamples[index]
		end
		averageRtt = sum / rttCount
	end

	return {
		Sent = totalSent,
		Received = totalReceived,
		Dropped = totalDropped,
		PerChannel = channels,
		AverageInvokeRtt = averageRtt,
		PacketLogEnabled = Config.Get().DebugMode,
	}
end

--[=[
	Returns the recent packet log, oldest first (up to 128 entries; only
	populated while DebugMode is on).
]=]
function Stats.getPacketLog(): { PacketLogEntry }
	local result = table.create(packetLogCount)
	for offset = packetLogCount - 1, 0, -1 do
		local index = (packetLogIndex - 1 - offset) % PACKET_LOG_CAPACITY + 1
		table.insert(result, packetLog[index])
	end
	return result
end

--[=[ Test-only: zeroes everything. ]=]
function Stats.clearAll()
	totalSent = 0
	totalReceived = 0
	totalDropped = 0
	table.clear(perChannel)
	table.clear(packetLog)
	packetLogIndex = 0
	packetLogCount = 0
	table.clear(rttSamples)
	rttIndex = 0
	rttCount = 0
end

return Stats
