--!strict
--[=[
	@class RemoteRegistry

	Owns every remote Instance the package uses.

	Layout (under `ReplicatedStorage[Config.RemoteFolderName]`):

	```
	_Networking/
	└── <ChannelName>/          (Folder, one per channel)
	    ├── Reliable            (RemoteEvent)
	    ├── Unreliable          (UnreliableRemoteEvent)
	    └── Function            (RemoteFunction)
	```

	One trio per **channel**, not per event — events are multiplexed by name
	inside the envelope. Fewer instances, cheaper client discovery, and event
	names become data the security layer can reason about.

	Server: creates lazily, idempotent. Client: discovers via WaitForChild.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)
local Log = require(script.Parent.Parent.Utilities.Log)

export type ChannelRemotes = {
	Reliable: RemoteEvent,
	Unreliable: UnreliableRemoteEvent,
	Function: RemoteFunction,
}

local RemoteRegistry = {}

local cache: { [string]: ChannelRemotes } = {}
local rootFolder: Folder? = nil

local function getRootServer(): Folder
	if rootFolder then
		return rootFolder :: Folder
	end
	local name = Config.Get().RemoteFolderName
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil and existing:IsA("Folder") then
		rootFolder = existing
	else
		assert(existing == nil, `ReplicatedStorage.{name} exists but is not a Folder`)
		local created = Instance.new("Folder")
		created.Name = name
		created.Parent = ReplicatedStorage
		rootFolder = created
	end
	return (rootFolder :: any) :: Folder
end

local function getRootClient(timeout: number?): Folder?
	if rootFolder then
		return rootFolder
	end
	local name = Config.Get().RemoteFolderName
	local found = if timeout ~= nil
		then ReplicatedStorage:WaitForChild(name, timeout)
		else ReplicatedStorage:WaitForChild(name)
	if found ~= nil and found:IsA("Folder") then
		rootFolder = found
		return found
	end
	return nil
end

local function createRemote(className: string, name: string, parent: Instance): Instance
	local existing = parent:FindFirstChild(name)
	if existing ~= nil and existing:IsA(className) then
		return existing
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = parent
	return remote
end

--[=[
	@server
	Returns (creating if needed) the remote trio for a channel. Idempotent —
	repeated calls return the same Instances.
]=]
function RemoteRegistry.getServer(channelName: string): ChannelRemotes
	assert(RunService:IsServer(), "RemoteRegistry.getServer can only be called on the server")

	local cached = cache[channelName]
	if cached then
		return cached
	end

	local root = getRootServer()
	local channelFolder: Instance
	local existingChannel = root:FindFirstChild(channelName)
	if existingChannel ~= nil and existingChannel:IsA("Folder") then
		channelFolder = existingChannel
	else
		local created = Instance.new("Folder")
		created.Name = channelName
		created.Parent = root
		channelFolder = created
	end

	local remotes: ChannelRemotes = {
		Reliable = createRemote("RemoteEvent", "Reliable", channelFolder) :: RemoteEvent,
		Unreliable = createRemote("UnreliableRemoteEvent", "Unreliable", channelFolder) :: UnreliableRemoteEvent,
		Function = createRemote("RemoteFunction", "Function", channelFolder) :: RemoteFunction,
	}
	cache[channelName] = remotes
	Log.Debug("Created remotes for channel %q", channelName)
	return remotes
end

--[=[
	@client
	Discovers the remote trio for a channel. Yields until the server has
	created it. `timeout = nil` waits indefinitely (listener binding);
	a number bounds the wait (outbound Fire) and returns nil on expiry.
]=]
function RemoteRegistry.getClient(channelName: string, timeout: number?): ChannelRemotes?
	assert(RunService:IsClient(), "RemoteRegistry.getClient can only be called on the client")

	local cached = cache[channelName]
	if cached then
		return cached
	end

	local deadline = if timeout ~= nil then os.clock() + timeout else nil
	local function remaining(): number?
		if deadline == nil then
			return nil
		end
		return math.max(deadline - os.clock(), 0.05)
	end

	local root = getRootClient(remaining())
	if root == nil then
		return nil
	end

	local function waitFor(parent: Instance, name: string): Instance?
		local budget = remaining()
		return if budget ~= nil then parent:WaitForChild(name, budget) else parent:WaitForChild(name)
	end

	local channelFolder = waitFor(root, channelName)
	if channelFolder == nil then
		return nil
	end

	local reliable = waitFor(channelFolder, "Reliable")
	local unreliable = waitFor(channelFolder, "Unreliable")
	local remoteFunction = waitFor(channelFolder, "Function")
	if reliable == nil or unreliable == nil or remoteFunction == nil then
		return nil
	end

	-- Another thread may have finished discovery while this one yielded.
	local raced = cache[channelName]
	if raced then
		return raced
	end

	local remotes: ChannelRemotes = {
		Reliable = reliable :: RemoteEvent,
		Unreliable = unreliable :: UnreliableRemoteEvent,
		Function = remoteFunction :: RemoteFunction,
	}
	cache[channelName] = remotes
	Log.Debug("Discovered remotes for channel %q", channelName)
	return remotes
end

--[=[
	Test-only escape hatch: clears the instance cache so specs can exercise
	creation paths repeatedly. Does not destroy instances.
]=]
function RemoteRegistry.clearCache()
	table.clear(cache)
	rootFolder = nil
end

return RemoteRegistry
